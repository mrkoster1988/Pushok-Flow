package shop.pushok.flow

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import java.io.InputStream
import java.io.OutputStream
import java.security.Key
import java.security.KeyStoreException
import java.security.KeyStoreSpi
import java.security.Provider
import java.security.ProviderException
import java.security.SecureRandom
import java.security.Security
import java.security.UnrecoverableKeyException
import java.security.cert.Certificate
import java.security.spec.AlgorithmParameterSpec
import java.util.Base64
import java.util.Collections
import java.util.Date
import javax.crypto.Cipher
import javax.crypto.KeyGeneratorSpi
import javax.crypto.SecretKey
import javax.crypto.spec.SecretKeySpec

private const val ACCOUNT_ALIAS = "pushok_flow_account_v1"
private const val PROFILE_ALIAS = "pushok_flow_wireguard_v1"
private const val NOW = 1_800_000_000_000L
private val accountAad = "shop.pushok.flow/account-record/v1".toByteArray(Charsets.UTF_8)
private val commit: (() -> Unit) -> Unit = { it() }
private val noRemote = FlowAccountRemote { _, _, _, _ -> error("Local storage work must not access the network") }
private val pending = FlowAccountRecord(pending = FlowAccountPending("pfd_" + "a".repeat(43),
    "2345ABCDEFGH", NOW + 300_000, NOW + 5000, 5))
private val session = FlowAccountRecord(session = FlowAccountSession("pfa_" + "b".repeat(64), NOW + 43_200_000,
    FlowAccountProfile("12345678-1234-1234-1234-123456789abc", "Аккаунт", "user", true,
        mapOf("RUB" to -101L, "BONUS" to 0L, "XTR" to 42L)), NOW, "2345ABCDEFGH"))

/** Synthetic provider only; AES-GCM still uses the JVM's actual Cipher implementation. */
object AccountStoreFixtureKeys {
    val values = mutableMapOf<String, Key>()
    val events = mutableListOf<String>()
    var unavailable = false
    var rejectDelete = false
    var rejectGenerate = false
    var mismatchedGeneratedKey = false
    var generations = 0
    fun reset() {
        values.clear(); events.clear()
        unavailable = false; rejectDelete = false; rejectGenerate = false; mismatchedGeneratedKey = false
        generations = 0
    }
}

class AccountStoreFixtureKeyStore : KeyStoreSpi() {
    override fun engineGetKey(alias: String, password: CharArray?): Key? {
        AccountStoreFixtureKeys.events += "get:$alias"
        if (alias == ACCOUNT_ALIAS && AccountStoreFixtureKeys.unavailable)
            throw UnrecoverableKeyException("Synthetic unavailable account key")
        return AccountStoreFixtureKeys.values[alias]
    }
    override fun engineDeleteEntry(alias: String) {
        AccountStoreFixtureKeys.events += "delete:$alias"
        if (AccountStoreFixtureKeys.rejectDelete) throw KeyStoreException("Synthetic deletion failure")
        AccountStoreFixtureKeys.values.remove(alias)
        if (alias == ACCOUNT_ALIAS) AccountStoreFixtureKeys.unavailable = false
    }
    override fun engineGetCertificateChain(alias: String): Array<Certificate>? = null
    override fun engineGetCertificate(alias: String): Certificate? = null
    override fun engineGetCreationDate(alias: String): Date? = Date(0)
    override fun engineSetKeyEntry(alias: String, key: Key, password: CharArray?, chain: Array<Certificate>?) = error("Not used")
    override fun engineSetKeyEntry(alias: String, key: ByteArray, chain: Array<Certificate>?) = error("Not used")
    override fun engineSetCertificateEntry(alias: String, certificate: Certificate) = error("Not used")
    override fun engineAliases() = Collections.enumeration(AccountStoreFixtureKeys.values.keys)
    override fun engineContainsAlias(alias: String) = AccountStoreFixtureKeys.values.containsKey(alias)
    override fun engineSize() = AccountStoreFixtureKeys.values.size
    override fun engineIsKeyEntry(alias: String) = engineContainsAlias(alias)
    override fun engineIsCertificateEntry(alias: String) = false
    override fun engineGetCertificateAlias(cert: Certificate): String? = null
    override fun engineStore(stream: OutputStream?, password: CharArray?) = Unit
    override fun engineLoad(stream: InputStream?, password: CharArray?) = Unit
}

class AccountStoreFixtureGenerator : KeyGeneratorSpi() {
    private var alias: String? = null
    override fun engineInit(random: SecureRandom?) = error("Not used")
    override fun engineInit(size: Int, random: SecureRandom?) = error("Not used")
    override fun engineInit(spec: AlgorithmParameterSpec, random: SecureRandom?) {
        val value = spec as KeyGenParameterSpec
        check(value.alias == ACCOUNT_ALIAS && value.purposes == 3)
        check(value.blockModes == listOf("GCM") && value.paddings == listOf("NoPadding") && value.keySize == 256)
        alias = value.alias
    }
    override fun engineGenerateKey(): SecretKey {
        AccountStoreFixtureKeys.events += "generate:$alias"
        if (AccountStoreFixtureKeys.rejectGenerate) throw ProviderException("Synthetic generation failure")
        val sequence = ++AccountStoreFixtureKeys.generations
        val generated = SecretKeySpec(ByteArray(32) { sequence.toByte() }, "AES")
        AccountStoreFixtureKeys.values[alias!!] = if (AccountStoreFixtureKeys.mismatchedGeneratedKey)
            SecretKeySpec(ByteArray(32) { (sequence + 64).toByte() }, "AES") else generated
        return generated
    }
}

class AccountStoreFixtureProvider : Provider("AndroidKeyStore", "1.0", "JVM fixture; no Android keys") {
    init {
        put("KeyStore.AndroidKeyStore", AccountStoreFixtureKeyStore::class.java.name)
        put("KeyGenerator.AES", AccountStoreFixtureGenerator::class.java.name)
    }
}

private class Fixture(record: FlowAccountRecord = session) {
    val context = Context()
    val preferences = context.getSharedPreferences(ACCOUNT_ALIAS, Context.MODE_PRIVATE)
    val store: FlowAccountStore
    val originalKey: Key
    val profileKey = SecretKeySpec(ByteArray(32) { 99.toByte() }, "AES")
    init {
        AccountStoreFixtureKeys.reset()
        AccountStoreFixtureKeys.values[PROFILE_ALIAS] = profileKey
        context.getSharedPreferences("flow_encrypted_profile", Context.MODE_PRIVATE).edit()
            .putString("ciphertext", "unrelated profile fixture").commit()
        preferences.edit().putString("unrelated", "preserve this preference").commit()
        store = FlowAccountStore(context)
        store.save(record)
        originalKey = AccountStoreFixtureKeys.values.getValue(ACCOUNT_ALIAS)
        check(FlowAccountStore(context.recreated()).load() == record)
        AccountStoreFixtureKeys.events.clear()
        preferences.onCommit = { changes, success ->
            check(changes.keys == setOf("record"))
            AccountStoreFixtureKeys.events += if (success) "commit" else "commit-failed"
        }
    }
    fun unchangedOtherStorage() {
        check(AccountStoreFixtureKeys.values[PROFILE_ALIAS] === profileKey)
        check(AccountStoreFixtureKeys.values.keys.all { it in setOf(ACCOUNT_ALIAS, PROFILE_ALIAS) })
        check(context.getSharedPreferences("flow_encrypted_profile", Context.MODE_PRIVATE)
            .getString("ciphertext", null) == "unrelated profile fixture")
        check(preferences.getString("unrelated", null) == "preserve this preference")
        check(AccountStoreFixtureKeys.events.filter { it.startsWith("delete:") }.all { it == "delete:$ACCOUNT_ALIAS" })
    }
}

private fun failure(code: String = "FLOW_STORE_UNAVAILABLE", action: () -> Unit) {
    try { action(); error("Expected $code") }
    catch (failure: FlowAccountFailure) { check(failure.code == code) { "Expected $code, got ${failure.code}" } }
}

private fun encrypt(record: Map<String, Any?>, key: Key): String {
    val plain = FlowAccountJson.encode(record)
    return try {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key)
        cipher.updateAAD(accountAad)
        Base64.getEncoder().encodeToString(byteArrayOf(1) + cipher.iv + cipher.doFinal(plain))
    } finally { plain.fill(0) }
}

fun main() {
    // Never substitute this fixture for a real Android provider or use real user/account keys.
    check(Security.getProvider("AndroidKeyStore") == null)
    Security.addProvider(AccountStoreFixtureProvider())
    try {
        for (record in listOf(pending, session, session.copy(session = session.session!!.copy(
            profile = null, refreshedAt = null, loginUserCode = null)))) {
            val fixture = Fixture(record)
            val before = fixture.preferences.getString("record", null)
            failure("FLOW_RECOVERY_NOT_REQUIRED") { fixture.store.recoverLocalAccount() }
            check(fixture.preferences.getString("record", null) == before)
            fixture.store.save(record)
            check(FlowAccountStore(fixture.context.recreated()).load() == record)
            check(fixture.preferences.getString("record", null) != before) // fresh randomized IV
            check(AccountStoreFixtureKeys.generations == 1 && AccountStoreFixtureKeys.values[ACCOUNT_ALIAS] === fixture.originalKey)
            check(AccountStoreFixtureKeys.events.none { it.startsWith("delete:") })
            fixture.unchangedOtherStorage()
        }

        // Actual encrypted v1 record migration preserves the session/profile, without rotating its key.
        run {
            val fixture = Fixture()
            val old = mapOf("version" to 1, "pending" to null,
                "session" to (FlowAccountPolicy.map(FlowAccountPolicy.record(session)["session"]) - "login_user_code"))
            fixture.preferences.edit().putString("record", encrypt(old, fixture.originalKey)).commit()
            val loaded = fixture.store.load()
            check(loaded == session.copy(session = session.session!!.copy(loginUserCode = null)))
            fixture.store.save(loaded)
            check(FlowAccountStore(fixture.context.recreated()).load() == loaded)
            check(AccountStoreFixtureKeys.generations == 1 && AccountStoreFixtureKeys.events.none { it.startsWith("delete:") })
            fixture.unchangedOtherStorage()
        }

        // A transient provider/read failure preserves both ciphertext and key for a fresh process.
        run {
            val fixture = Fixture()
            val before = fixture.preferences.getString("record", null)
            AccountStoreFixtureKeys.unavailable = true
            val manager = FlowAccountSessionManager(fixture.store) { NOW }
            repeat(2) { failure { manager.execute("status", noRemote, commit) } }
            failure { manager.execute("beginLogin", noRemote, commit) }
            check(manager.recoveryAvailable && manager.record == FlowAccountRecord())
            check(fixture.preferences.getString("record", null) == before && fixture.preferences.durable["record"] == before)
            AccountStoreFixtureKeys.unavailable = false
            check(FlowAccountStore(fixture.context.recreated()).load() == session)
            check(AccountStoreFixtureKeys.values[ACCOUNT_ALIAS] === fixture.originalKey && AccountStoreFixtureKeys.generations == 1)
            check(AccountStoreFixtureKeys.events.none { it == "commit" || it.startsWith("delete:") })
            fixture.unchangedOtherStorage()
        }

        // The original trap also occurs with an empty record left by an earlier version: status
        // looks signed out, but the existing unusable alias rejects the first newly issued code.
        run {
            val fixture = Fixture()
            fixture.store.save(FlowAccountRecord())
            AccountStoreFixtureKeys.unavailable = true
            val manager = FlowAccountSessionManager(FlowAccountStore(fixture.context)) { NOW }
            manager.execute("status", noRemote, commit)
            check(!manager.recoveryAvailable)
            val calls = mutableListOf<String>()
            val remote = FlowAccountRemote { _, path, _, _ ->
                calls += path
                when (path) {
                    "/capabilities" -> FlowAccountResponse(200, mapOf("protocol_version" to 1,
                        "scopes" to listOf("profile:read", "wallet:read"), "session_ttl_seconds" to 43200))
                    "/device" -> FlowAccountResponse(201, mapOf("device_code" to "pfd_" + "c".repeat(43),
                        "user_code" to "6789ABCDEFGH", "expires_in" to 300, "interval" to 5))
                    else -> error("Unexpected endpoint")
                }
            }
            failure { manager.execute("beginLogin", remote, commit) }
            check(manager.recoveryAvailable && manager.record == FlowAccountRecord())
            check(calls == listOf("/capabilities", "/device") && AccountStoreFixtureKeys.values[ACCOUNT_ALIAS] === fixture.originalKey)
            failure { manager.execute("beginLogin", noRemote, commit) }
            manager.execute("recoverLocalAccount", noRemote, commit)
            check(!manager.recoveryAvailable && fixture.preferences.durable["record"] == null)
            manager.execute("beginLogin", remote, commit)
            check(manager.record.pending?.userCode == "6789ABCDEFGH")
            check(FlowAccountStore(fixture.context.recreated()).load() == manager.record)
            check(AccountStoreFixtureKeys.values[ACCOUNT_ALIAS] !== fixture.originalKey)
            fixture.unchangedOtherStorage()
        }

        // Authenticated decryption and strict format failures also require explicit recovery.
        for (corruption in listOf("base64", "header", "tag", "schema")) {
            val fixture = Fixture()
            val valid = fixture.preferences.getString("record", null)!!
            val broken = when (corruption) {
                "base64" -> "not base64"
                "header" -> Base64.getEncoder().encodeToString(byteArrayOf(2) + ByteArray(40))
                "schema" -> encrypt(mapOf("version" to 9, "pending" to null, "session" to null), fixture.originalKey)
                else -> Base64.getEncoder().encodeToString(Base64.getDecoder().decode(valid).also {
                    it[it.lastIndex] = (it.last().toInt() xor 1).toByte()
                })
            }
            fixture.preferences.edit().putString("record", broken).commit()
            val manager = FlowAccountSessionManager(fixture.store) { NOW }
            failure { manager.execute("status", noRemote, commit) }
            check(fixture.preferences.getString("record", null) == broken && manager.recoveryAvailable)
            manager.execute("recoverLocalAccount", noRemote, commit)
            check(!manager.recoveryAvailable && manager.record == FlowAccountRecord())
            check(fixture.preferences.durable["record"] == null && AccountStoreFixtureKeys.values[ACCOUNT_ALIAS] !== fixture.originalKey)
            fixture.unchangedOtherStorage()
        }

        // Every partial failure stays unavailable. In particular a false commit can remove the
        // in-memory record while its durable copy remains; that must never permit key deletion.
        for (stage in listOf("clear", "delete", "generate", "self-check")) {
            val fixture = Fixture()
            val oldCiphertext = fixture.preferences.durable["record"]
            AccountStoreFixtureKeys.unavailable = true
            val manager = FlowAccountSessionManager(fixture.store) { NOW }
            failure { manager.execute("status", noRemote, commit) }
            when (stage) {
                "clear" -> fixture.preferences.failCommit = true
                "delete" -> AccountStoreFixtureKeys.rejectDelete = true
                "generate" -> AccountStoreFixtureKeys.rejectGenerate = true
                else -> AccountStoreFixtureKeys.mismatchedGeneratedKey = true
            }
            AccountStoreFixtureKeys.events.clear()
            failure { manager.execute("recoverLocalAccount", noRemote, commit) }
            check(manager.recoveryAvailable && manager.record == FlowAccountRecord())
            failure { manager.execute("beginLogin", noRemote, commit) }
            if (stage == "clear") {
                check(fixture.preferences.durable["record"] == oldCiphertext)
                check(AccountStoreFixtureKeys.values[ACCOUNT_ALIAS] === fixture.originalKey)
                check(AccountStoreFixtureKeys.events == listOf("commit-failed"))
            } else {
                check(fixture.preferences.durable["record"] == null)
                check(AccountStoreFixtureKeys.events.take(2) == listOf("commit", "delete:$ACCOUNT_ALIAS"))
            }
            fixture.unchangedOtherStorage()
            fixture.preferences.failCommit = false
            AccountStoreFixtureKeys.rejectDelete = false
            AccountStoreFixtureKeys.rejectGenerate = false
            AccountStoreFixtureKeys.mismatchedGeneratedKey = false
            AccountStoreFixtureKeys.events.clear()
            manager.execute("recoverLocalAccount", noRemote, commit)
            check(!manager.recoveryAvailable && manager.record == FlowAccountRecord())
            check(fixture.preferences.durable["record"] == null && AccountStoreFixtureKeys.values[ACCOUNT_ALIAS] !== fixture.originalKey)
            check(AccountStoreFixtureKeys.events == listOf("commit", "delete:$ACCOUNT_ALIAS", "get:$ACCOUNT_ALIAS",
                "generate:$ACCOUNT_ALIAS", "get:$ACCOUNT_ALIAS")) // includes retrieving the fresh key for decryption
            val remoteCalls = mutableListOf<String>()
            manager.execute("beginLogin", FlowAccountRemote { _, path, _, _ ->
                remoteCalls += path
                when (path) {
                    "/capabilities" -> FlowAccountResponse(200, mapOf("protocol_version" to 1,
                        "scopes" to listOf("profile:read", "wallet:read"), "session_ttl_seconds" to 43200))
                    "/device" -> FlowAccountResponse(201, mapOf("device_code" to "pfd_" + "c".repeat(43),
                        "user_code" to "6789ABCDEFGH", "expires_in" to 300, "interval" to 5))
                    else -> error("Unexpected endpoint")
                }
            }, commit)
            check(remoteCalls == listOf("/capabilities", "/device") && manager.record.pending?.userCode == "6789ABCDEFGH")
            check(FlowAccountStore(fixture.context.recreated()).load() == manager.record)
            failure("FLOW_RECOVERY_NOT_REQUIRED") { manager.execute("recoverLocalAccount", noRemote, commit) }
            check(FlowAccountStore(fixture.context.recreated()).load() == manager.record)
            fixture.unchangedOtherStorage()
        }
        println("Actual account store: AES-GCM/v1-v2 round trips, preserved failed reads, explicit account-only reset, durable ordering and retry at every reset stage passed")
    } finally { Security.removeProvider("AndroidKeyStore") }
}
