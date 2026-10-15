package com.follow.flashco

import android.app.Application
import android.content.Context
import com.follow.flashco.common.GlobalState

class FlashcoApplication : Application() {
    override fun attachBaseContext(base: Context?) {
        super.attachBaseContext(base)
        GlobalState.init(this)
    }
}
