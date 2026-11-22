import java.io.ByteArrayInputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.security.KeyStore;
import java.security.MessageDigest;
import java.security.PrivateKey;
import java.security.Signature;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.security.interfaces.RSAPublicKey;
import java.util.Arrays;
import java.util.HexFormat;

/** Java 17 source-mode helper; private credentials are environment-only. */
class RecommendationSignature {
    private static final byte[] DOMAIN =
        "Pushok Flow route recommendations v1\n".getBytes(StandardCharsets.UTF_8);
    private static final int MAX_PAYLOAD = 65536;

    private static byte[] bounded(Path path, int maximum) throws Exception {
        try (InputStream stream = Files.newInputStream(path)) {
            byte[] data = stream.readNBytes(maximum + 1);
            if (data.length == 0 || data.length > maximum) {
                throw new IllegalArgumentException();
            }
            return data;
        }
    }

    private static String requiredEnvironment(String name) {
        String value = System.getenv(name);
        if (value == null || value.isEmpty()) throw new IllegalArgumentException();
        return value;
    }

    private static Signature verifier(X509Certificate certificate, byte[] payload) throws Exception {
        Signature verifier = Signature.getInstance("SHA256withRSA");
        verifier.initVerify(certificate.getPublicKey());
        verifier.update(DOMAIN);
        verifier.update(payload);
        return verifier;
    }

    private static void run(String[] args) throws Exception {
        if (args.length != 5 || !(args[0].equals("sign") || args[0].equals("verify"))
                || !args[4].matches("[0-9a-f]{64}")) throw new IllegalArgumentException();
        byte[] certificateBytes = bounded(Path.of(args[1]), 16384);
        X509Certificate certificate = (X509Certificate) CertificateFactory.getInstance("X.509")
            .generateCertificate(new ByteArrayInputStream(certificateBytes));
        String digest = HexFormat.of().formatHex(
            MessageDigest.getInstance("SHA-256").digest(certificate.getEncoded()));
        if (!MessageDigest.isEqual(digest.getBytes(StandardCharsets.US_ASCII),
                                    args[4].getBytes(StandardCharsets.US_ASCII))) {
            throw new IllegalArgumentException();
        }
        if (!(certificate.getPublicKey() instanceof RSAPublicKey rsa)
                || rsa.getModulus().bitLength() < 2048 || rsa.getModulus().bitLength() > 8192) {
            throw new IllegalArgumentException();
        }
        byte[] payload = bounded(Path.of(args[2]), MAX_PAYLOAD);
        Path signaturePath = Path.of(args[3]);
        if (args[0].equals("verify")) {
            byte[] signature = bounded(signaturePath, 1024);
            if (signature.length < 256 || !verifier(certificate, payload).verify(signature)) {
                throw new IllegalArgumentException();
            }
            return;
        }

        char[] storePassword = requiredEnvironment("FLOW_DATA_STORE_PASSWORD").toCharArray();
        char[] keyPassword = requiredEnvironment("FLOW_DATA_KEY_PASSWORD").toCharArray();
        byte[] signature;
        try {
            KeyStore store = KeyStore.getInstance(
                Path.of(requiredEnvironment("FLOW_DATA_KEYSTORE")).toFile(), storePassword);
            String alias = requiredEnvironment("FLOW_DATA_KEY_ALIAS");
            java.security.cert.Certificate storedCertificate = store.getCertificate(alias);
            if (storedCertificate == null || !MessageDigest.isEqual(
                    storedCertificate.getEncoded(), certificate.getEncoded())) {
                throw new IllegalArgumentException();
            }
            java.security.Key key = store.getKey(alias, keyPassword);
            if (!(key instanceof PrivateKey privateKey) || !key.getAlgorithm().equals("RSA")) {
                throw new IllegalArgumentException();
            }
            Signature signer = Signature.getInstance("SHA256withRSA");
            signer.initSign(privateKey);
            signer.update(DOMAIN);
            signer.update(payload);
            signature = signer.sign();
            if (signature.length < 256 || signature.length > 1024
                    || !verifier(certificate, payload).verify(signature)) {
                throw new IllegalArgumentException();
            }
        } finally {
            Arrays.fill(storePassword, '\0');
            Arrays.fill(keyPassword, '\0');
        }
        Path destination = signaturePath.toAbsolutePath();
        Path temporary = Files.createTempFile(destination.getParent(), ".recommendation-signature-", ".tmp");
        try {
            Files.write(temporary, signature);
            Files.move(temporary, destination, StandardCopyOption.ATOMIC_MOVE,
                       StandardCopyOption.REPLACE_EXISTING);
        } finally {
            Files.deleteIfExists(temporary);
        }
    }

    public static void main(String[] args) {
        try {
            run(args);
            System.out.println("Recommendation signature verified.");
        } catch (Exception failure) {
            // Never reflect exception messages, keystore details, or passwords.
            System.err.println("Recommendation signature operation failed.");
            System.exit(1);
        }
    }
}
