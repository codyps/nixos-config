import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.security.KeyStore;
import java.security.MessageDigest;
import java.security.cert.CertificateFactory;
import java.io.ByteArrayInputStream;
import java.util.Base64;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Convert the ordinary, server-trusted entries of a Nix CA bundle. */
public final class BuildJavaTrustStore {
    public static void main(String[] args) throws Exception {
        String pem = new String(Files.readAllBytes(Paths.get(args[0])), StandardCharsets.US_ASCII);
        // Nix/buildcatrust also emits TRUSTED CERTIFICATE entries carrying AUX
        // trust/reject flags. Importing those as plain X.509 would restore trust.
        Matcher entries = Pattern.compile(
            "-----BEGIN CERTIFICATE-----\\s+([A-Za-z0-9+/=\\s]+)-----END CERTIFICATE-----"
        ).matcher(pem);
        KeyStore store = KeyStore.getInstance("PKCS12");
        store.load(null, "changeit".toCharArray());
        CertificateFactory factory = CertificateFactory.getInstance("X.509");
        MessageDigest sha256 = MessageDigest.getInstance("SHA-256");
        int count = 0;
        while (entries.find()) {
            byte[] der = Base64.getDecoder().decode(entries.group(1).replaceAll("\\s", ""));
            java.security.cert.Certificate cert = factory.generateCertificate(new ByteArrayInputStream(der));
            StringBuilder alias = new StringBuilder();
            for (byte b : sha256.digest(cert.getEncoded())) {
                alias.append(String.format("%02x", b & 0xff));
            }
            store.setCertificateEntry(alias.toString(), cert);
            count++;
        }
        // Do not silently omit malformed ordinary PEM entries or create an empty
        // store when a bundle uses an unsupported (e.g. trusted-only) format.
        int starts = pem.split("-----BEGIN CERTIFICATE-----", -1).length - 1;
        if (count == 0 || count != starts) {
            throw new IllegalArgumentException("Expected a nonempty compatible PEM CA bundle");
        }
        try (OutputStream output = Files.newOutputStream(Paths.get(args[1]))) {
            store.store(output, "changeit".toCharArray());
        }
    }
}
