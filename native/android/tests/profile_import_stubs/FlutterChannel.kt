package io.flutter.plugin.common

class MethodChannel {
    interface Result {
        fun success(value: Any?)
        fun error(code: String, message: String?, details: Any?)
        fun notImplemented()
    }
}
