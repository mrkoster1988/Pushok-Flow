package shop.pushok.flow

/** Deterministic WireGuard application routing. Does not log credentials. */
object WireGuardRouting {
    private val packagePattern = Regex("[A-Za-z0-9_]+(\\.[A-Za-z0-9_]+)+")
    private val interfaceHeader = Regex("^\\[Interface]$", RegexOption.IGNORE_CASE)
    private val applicationKeys = setOf("includedapplications", "excludedapplications")

    fun prepare(raw: String, exclusions: Set<String>): String {
        require(exclusions.all { packagePattern.matches(it) }) { "Некорректный идентификатор приложения" }
        require(raw.length <= 65536) { "Слишком большая конфигурация" }
        val lines = raw.replace("\r\n", "\n").replace("\r", "\n").split("\n")
        require(lines.count { interfaceHeader.matches(it.trim()) } == 1) { "Нужна ровно одна секция Interface" }

        // Existing application routing settings may appear ONLY in [Interface].
        // Reject misplaced options, including keys in [Peer], instead of silently
        // passing them to the WireGuard configuration parser.
        var section = ""
        for (line in lines) {
            val trimmed = line.substringBefore('#').trim()
            if (trimmed.startsWith("[") && trimmed.endsWith("]")) {
                section = trimmed.lowercase()
                continue
            }
            if ('=' !in trimmed) continue
            val key = trimmed.substringBefore('=').trim().lowercase()
            if (key in applicationKeys) {
                require(section == "[interface]") { "Параметр маршрутизации вне секции Interface" }
                require(key != "includedapplications") { "IncludedApplications несовместим с исключениями" }
            }
        }

        val output = mutableListOf<String>()
        var inInterface = false
        var inserted = false
        for (line in lines) {
            val trimmed = line.trim()
            if (trimmed.startsWith("[") && trimmed.endsWith("]")) {
                if (inInterface && !inserted) {
                    if (exclusions.isNotEmpty()) output.add("ExcludedApplications = " + exclusions.sorted().joinToString(", "))
                    inserted = true
                }
                inInterface = interfaceHeader.matches(trimmed)
            }
            if (inInterface && trimmed.substringBefore('#').substringBefore('=', "").trim().equals("ExcludedApplications", ignoreCase = true)) continue
            output.add(line)
        }
        if (inInterface && !inserted && exclusions.isNotEmpty())
            output.add("ExcludedApplications = " + exclusions.sorted().joinToString(", "))
        return output.joinToString("\n")
    }
}