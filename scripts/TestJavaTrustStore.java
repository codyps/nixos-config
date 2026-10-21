import java.security.KeyStore;
import java.security.MessageDigest;
import java.security.cert.X509Certificate;
import javax.net.ssl.TrustManager;
import javax.net.ssl.TrustManagerFactory;
import javax.net.ssl.X509TrustManager;

/** Print the actual default JSSE anchors, without opening the store directly. */
public final class TestJavaTrustStore {
    public static void main(String[] args) throws Exception {
        TrustManagerFactory factory = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
        factory.init((KeyStore) null);
        MessageDigest sha256 = MessageDigest.getInstance("SHA-256");
        for (TrustManager manager : factory.getTrustManagers()) {
            if (manager instanceof X509TrustManager) {
                for (X509Certificate cert : ((X509TrustManager) manager).getAcceptedIssuers()) {
                    StringBuilder fingerprint = new StringBuilder();
                    for (byte b : sha256.digest(cert.getEncoded())) {
                        fingerprint.append(String.format("%02x", b & 0xff));
                    }
                    System.out.println(fingerprint);
                }
            }
        }
    }
}
