package com.follow.flashco.service.models

data class NotificationParams(
    val title: String = "Flashco",
    val stopText: String = "STOP",
    val onlyStatisticsProxy: Boolean = false,
    val showStopAction: Boolean = true,
)
