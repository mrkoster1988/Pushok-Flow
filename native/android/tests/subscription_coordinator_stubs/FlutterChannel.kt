package io.flutter.plugin.common

interface BinaryMessenger
class MethodCall(val method: String, val arguments: Any? = null)

class MethodChannel(private val messenger: BinaryMessenger, name: String) {
    interface Result {
        fun success(value: Any?)
        fun error(code: String, message: String?, details: Any?)
        fun notImplemented()
    }
    fun setMethodCallHandler(value: ((MethodCall, Result) -> Unit)?) {
        if (value == null) handlers.remove(messenger) else handlers[messenger] = value
    }
    fun invokeMethod(method: String, arguments: Any?) {}
    companion object {
        private val handlers = mutableMapOf<BinaryMessenger, (MethodCall, Result) -> Unit>()
        fun invoke(messenger: BinaryMessenger, method: String, arguments: Any?, result: Result) {
            (handlers[messenger] ?: error("Unregistered channel"))(MethodCall(method, arguments), result)
        }
    }
}
