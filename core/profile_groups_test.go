package core

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/metacubex/mihomo/adapter/outboundgroup"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
)

func profileGroupFixture(t *testing.T, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "profile.yaml")
	if err := os.WriteFile(path, []byte(content), 0600); err != nil {
		t.Fatal(err)
	}
	return path
}

type profileReferencesTestProxy struct {
	C.Proxy
	name string
	kind C.AdapterType
}

func (p profileReferencesTestProxy) Name() string        { return p.name }
func (p profileReferencesTestProxy) Type() C.AdapterType { return p.kind }

type profileReferencesTestProvider struct {
	P.ProxyProvider
	proxies []C.Proxy
	vehicle P.VehicleType
}

func (p profileReferencesTestProvider) Proxies() []C.Proxy         { return p.proxies }
func (p profileReferencesTestProvider) Version() uint32            { return 0 }
func (p profileReferencesTestProvider) VehicleType() P.VehicleType { return p.vehicle }

func TestProfileGroupReferencesMatchesNativeGroupBase(t *testing.T) {
	for _, test := range []struct {
		filter      string
		exclude     string
		excludeType string
		use         string
	}{
		{},
		{filter: "^Auto$`^Fast"},
		{filter: "^Auto$`^Fast", use: "use: [remote]"},
		{filter: "^Auto$`^Fast", use: "include-all-providers: true"},
		{exclude: "(?<=Fast)est$`^Safe$"},
		{excludeType: "uRlTeSt|Direct"},
		{filter: "^Auto$`^Fast", use: "use: [remote]", exclude: "^Auto$", excludeType: "Fallback"},
	} {
		t.Run(test.filter+test.exclude+test.excludeType+test.use, func(t *testing.T) {
			yaml := "proxy-providers: {remote: {type: http}}\nproxy-groups:\n" +
				"  - name: Route\n    type: select\n    proxies: [Safe, Fastest, Auto, Auto]\n" +
				"    filter: '" + test.filter + "'\n    exclude-filter: '" + test.exclude +
				"'\n    exclude-type: '" + test.excludeType + "'\n    " + test.use + "\n" +
				"  - {name: Safe, type: fallback, proxies: [DIRECT]}\n" +
				"  - {name: Fastest, type: url-test, proxies: [DIRECT]}\n" +
				"  - {name: Auto, type: url-test, proxies: [DIRECT]}\n"
			groups, err := handleGetProfileGroupReferences(profileGroupFixture(t, yaml))
			if err != nil {
				t.Fatal(err)
			}
			own := profileReferencesTestProvider{vehicle: P.Compatible, proxies: []C.Proxy{
				profileReferencesTestProxy{name: "Safe", kind: C.Fallback},
				profileReferencesTestProxy{name: "Fastest", kind: C.URLTest},
				profileReferencesTestProxy{name: "Auto", kind: C.URLTest},
				profileReferencesTestProxy{name: "Auto", kind: C.URLTest},
			}}
			providers := []P.ProxyProvider{own}
			if test.use != "" {
				providers = append(providers, profileReferencesTestProvider{vehicle: P.HTTP})
			}
			native := outboundgroup.NewGroupBase(outboundgroup.GroupBaseOption{
				Name: "Route", Type: C.Selector, Filter: test.filter,
				ExcludeFilter: test.exclude, ExcludeType: test.excludeType, Providers: providers,
				EmptyFallback: profileReferencesTestProxy{name: "COMPATIBLE", kind: C.Compatible},
			})
			want := make([]profileGroupReference, 0)
			for _, proxy := range native.GetProxies(false) {
				if proxy.Type() != C.Compatible {
					want = append(want, profileGroupReference{Name: proxy.Name(), Type: proxy.Type().String()})
				}
			}
			if !reflect.DeepEqual(groups[0].All, want) {
				t.Errorf("references = %+v, native GroupBase = %+v", groups[0].All, want)
			}
		})
	}
}

func TestProfileGroupReferencesNativeExclusions(t *testing.T) {
	path := filepath.Join("..", "test", "fixtures", "core", "profile_group_references.yaml")
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	statBefore, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	configBefore := currentConfig

	groups, err := handleGetProfileGroupReferences(path)
	if err != nil {
		t.Fatal(err)
	}
	want := [][]string{
		{"Auto", "Safe"},
		{"Safe"},
		{"Fastest", "Auto", "Safe"},
		{}, {}, {},
		{"PROXY", "Typed", "Ordered", "Fastest", "Auto", "Safe"},
	}
	if len(groups) != len(want) {
		t.Fatalf("groups = %+v, want %d groups", groups, len(want))
	}
	for i, group := range groups {
		names := make([]string, 0, len(group.All))
		for _, member := range group.All {
			names = append(names, member.Name)
		}
		if !reflect.DeepEqual(names, want[i]) {
			t.Errorf("%s members = %v, want %v", group.Name, names, want[i])
		}
	}
	if !groups[3].Hidden || groups[3].Type != "URLTest" || groups[0].All[0].Type != "URLTest" {
		t.Errorf("hidden/type metadata lost: %+v", groups)
	}
	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	statAfter, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(before, after) || statBefore.ModTime() != statAfter.ModTime() || currentConfig != configBefore {
		t.Error("read-only metadata operation changed the source file or active config")
	}
}

func TestProfileGroupReferencesEnvelopeFixture(t *testing.T) {
	path := filepath.Join("..", "test", "fixtures", "core", "profile_group_references.yaml")
	arguments, err := json.Marshal(path)
	if err != nil {
		t.Fatal(err)
	}
	frame := handleMethodCall(&MethodCall{
		ID: "profile-groups", Method: getProfileGroupRefsMethod, Arguments: arguments,
	})
	want, err := os.ReadFile(filepath.Join("..", "test", "fixtures", "core", "profile_group_references.json"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(bytes.TrimSpace(frame), bytes.TrimSpace(want)) {
		t.Fatalf("envelope = %s, want %s", frame, want)
	}
}

func TestProfileGroupReferencesMembershipAndGlobal(t *testing.T) {
	for _, test := range []struct {
		name string
		yaml string
		want string
	}{
		{"empty", "", `[{"name":"GLOBAL","type":"Selector","all":[]}]`},
		{"explicit global", `proxy-groups:
  - {name: GLOBAL, type: select, proxies: [Auto, Auto, DIRECT], filter: '^no-match$'}
  - {name: Auto, type: url-test, proxies: [DIRECT]}
`, `[{"name":"GLOBAL","type":"Selector","all":[{"name":"Auto","type":"URLTest"},{"name":"Auto","type":"URLTest"}]},{"name":"Auto","type":"URLTest","all":[]}]`},
		{"include all", `proxy-groups:
  - {name: All, type: select, include-all: true, filter: '^Auto$'}
  - {name: Auto, type: url-test, proxies: [DIRECT]}
`, `[{"name":"All","type":"Selector","all":[]},{"name":"Auto","type":"URLTest","all":[]},{"name":"GLOBAL","type":"Selector","all":[{"name":"All","type":"Selector"},{"name":"Auto","type":"URLTest"}]}]`},
		{"positive filter keeps explicit references", `proxy-groups:
  - {name: Route, type: select, proxies: [Safe, Auto], filter: '^Auto$` + "`" + `^Safe$'}
  - {name: Auto, type: url-test, proxies: [DIRECT]}
  - {name: Safe, type: load-balance, proxies: [DIRECT]}
`, `[{"name":"Route","type":"Selector","all":[{"name":"Safe","type":"LoadBalance"},{"name":"Auto","type":"URLTest"}]},{"name":"Auto","type":"URLTest","all":[]},{"name":"Safe","type":"LoadBalance","all":[]},{"name":"GLOBAL","type":"Selector","all":[{"name":"Route","type":"Selector"},{"name":"Auto","type":"URLTest"},{"name":"Safe","type":"LoadBalance"}]}]`},
	} {
		t.Run(test.name, func(t *testing.T) {
			groups, err := handleGetProfileGroupReferences(profileGroupFixture(t, test.yaml))
			if err != nil {
				t.Fatal(err)
			}
			got, err := json.Marshal(groups)
			if err != nil {
				t.Fatal(err)
			}
			if string(got) != test.want {
				t.Fatalf("metadata = %s, want %s", got, test.want)
			}
		})
	}
}

func TestProfileGroupReferencesRejectsMalformedInput(t *testing.T) {
	for _, yaml := range []string{
		"proxy-groups: [oops]", "proxy-groups: [null]",
		"proxy-groups: [{type: select}]", "proxy-groups: [{name: X, type: unsupported}]",
		"proxy-groups: [{name: X, type: select, proxies: 1}]",
		"proxy-groups: [{name: X, type: select, proxies: [DIRECT], filter: '['}]",
		"proxy-groups: [{name: X, type: select, proxies: [DIRECT], exclude-filter: '['}]",
		"proxy-groups: [{name: X, type: select, hidden: []}]",
		"proxy-groups: [{name: X, type: select}, {name: X, type: select}]",
	} {
		t.Run(yaml, func(t *testing.T) {
			if _, err := handleGetProfileGroupReferences(profileGroupFixture(t, yaml)); err == nil {
				t.Fatal("malformed group metadata was accepted")
			}
		})
	}
	if _, err := handleGetProfileGroupReferences(filepath.Join(t.TempDir(), "missing.yaml")); err == nil {
		t.Error("missing file was accepted")
	}
	frame := handleMethodCall(&MethodCall{Method: getProfileGroupRefsMethod, Arguments: json.RawMessage(`{}`)})
	var response MethodResponse
	if err := json.Unmarshal(frame, &response); err != nil {
		t.Fatal(err)
	}
	if response.Error == nil || response.Error.Code != "invalid_arguments" {
		t.Errorf("invalid arguments response = %s", frame)
	}
}
