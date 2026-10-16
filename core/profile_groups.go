package core

import (
	"fmt"
	"strings"

	"github.com/dlclark/regexp2"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/common/structure"
	C "github.com/metacubex/mihomo/constant"
)

type profileGroupReference struct {
	Name string `json:"name"`
	Type string `json:"type"`
}

type profileGroupReferences struct {
	Name   string                  `json:"name"`
	Type   string                  `json:"type"`
	Hidden bool                    `json:"hidden,omitempty"`
	All    []profileGroupReference `json:"all"`
}

func handleGetProfileGroupReferences(path string) ([]profileGroupReferences, error) {
	raw, err := handleGetConfig(path)
	if err != nil {
		return nil, err
	}
	options := make([]outboundgroup.GroupCommonOption, len(raw.ProxyGroup))
	groups := make([]profileGroupReferences, 0, len(options)+1)
	byName := make(map[string]string, len(options))
	decoder := structure.NewDecoder(structure.Option{TagName: "group", WeaklyTypedInput: true})
	for i, mapping := range raw.ProxyGroup {
		name, ok := mapping["name"].(string)
		if !ok || name == "" {
			return nil, fmt.Errorf("proxy group %d: missing name", i)
		}
		if err := decoder.Decode(mapping, &options[i]); err != nil {
			return nil, fmt.Errorf("proxy group %s: %w", name, err)
		}
		var adapterType C.AdapterType
		switch options[i].Type {
		case "select":
			adapterType = C.Selector
		case "url-test":
			adapterType = C.URLTest
		case "fallback":
			adapterType = C.Fallback
		case "load-balance":
			adapterType = C.LoadBalance
		default:
			return nil, fmt.Errorf("proxy group %s: unsupported type %q", name, options[i].Type)
		}
		if _, exists := byName[name]; exists {
			return nil, fmt.Errorf("proxy group %s: duplicate name", name)
		}
		byName[name] = adapterType.String()
		groups = append(groups, profileGroupReferences{
			Name: name, Type: adapterType.String(), Hidden: options[i].Hidden,
			All: make([]profileGroupReference, 0),
		})
	}
	for i, option := range options {
		filters, err := profileGroupFilters(option.Filter)
		if err != nil {
			return nil, fmt.Errorf("proxy group %s filter: %w", option.Name, err)
		}
		exclusions, err := profileGroupFilters(option.ExcludeFilter)
		if err != nil {
			return nil, fmt.Errorf("proxy group %s exclude-filter: %w", option.Name, err)
		}
		for _, name := range option.Proxies {
			if kind, exists := byName[name]; exists {
				groups[i].All = append(groups[i].All, profileGroupReference{Name: name, Type: kind})
			}
		}
		providerCount := len(option.Use)
		if option.IncludeAll || option.IncludeAllProviders {
			providerCount = len(raw.ProxyProvider)
		}
		// Explicit references form a compatible provider: GroupBase skips its
		// positive filter, but reorders across providers when there are several filters.
		if providerCount > 0 && len(filters) > 1 {
			groups[i].All, err = orderProfileGroupReferences(groups[i].All, filters)
			if err != nil {
				return nil, fmt.Errorf("proxy group %s filter: %w", option.Name, err)
			}
		}
		members := make([]profileGroupReference, 0, len(groups[i].All))
	MEMBER:
		for _, member := range groups[i].All {
			for _, filter := range exclusions {
				match, err := filter.MatchString(member.Name)
				if err != nil {
					return nil, fmt.Errorf("proxy group %s exclude-filter: %w", option.Name, err)
				}
				if match {
					continue MEMBER
				}
			}
			for _, kind := range strings.Split(option.ExcludeType, "|") {
				if strings.EqualFold(kind, member.Type) {
					continue MEMBER
				}
			}
			members = append(members, member)
		}
		groups[i].All = members
	}
	if _, explicit := byName["GLOBAL"]; !explicit {
		global := profileGroupReferences{Name: "GLOBAL", Type: C.Selector.String(), All: make([]profileGroupReference, 0, len(groups))}
		for _, group := range groups {
			global.All = append(global.All, profileGroupReference{Name: group.Name, Type: group.Type})
		}
		groups = append(groups, global)
	}
	return groups, nil
}

func profileGroupFilters(value string) ([]*regexp2.Regexp, error) {
	var filters []*regexp2.Regexp
	if value != "" {
		for _, part := range strings.Split(value, "`") {
			filter, err := regexp2.Compile(part, regexp2.None)
			if err != nil {
				return nil, err
			}
			filters = append(filters, filter)
		}
	}
	return filters, nil
}

func orderProfileGroupReferences(members []profileGroupReference, filters []*regexp2.Regexp) ([]profileGroupReference, error) {
	ordered := make([]profileGroupReference, 0, len(members))
	seen := make(map[string]bool, len(members))
	for _, filter := range filters {
		for _, member := range members {
			match, err := filter.MatchString(member.Name)
			if err != nil {
				return nil, err
			}
			if match && !seen[member.Name] {
				ordered = append(ordered, member)
				seen[member.Name] = true
			}
		}
	}
	for _, member := range members {
		if !seen[member.Name] {
			ordered = append(ordered, member)
			seen[member.Name] = true
		}
	}
	return ordered, nil
}
