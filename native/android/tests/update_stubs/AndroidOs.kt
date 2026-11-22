package android.os

object Build { object VERSION { var SDK_INT = 36 } }
object SystemClock { var now = 1000L; fun elapsedRealtime(): Long = now }
