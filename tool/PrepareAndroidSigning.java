import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.util.Base64;
import java.util.Properties;

public class PrepareAndroidSigning {
    private static final String[] REQUIRED_ENV = {
        "ANDROID_KEYSTORE_BASE64",
        "ANDROID_STORE_PASSWORD",
        "ANDROID_KEY_ALIAS",
        "ANDROID_KEY_PASSWORD"
    };

    public static void main(String[] args) {
        if (args.length != 0) {
            fail("This helper takes no arguments.");
        }
        String error = prepare();
        if (error != null) {
            fail(error);
        }
        System.out.println("Android signing material prepared.");
    }

    private static String prepare() {
        String[] values = new String[REQUIRED_ENV.length];
        for (int i = 0; i < REQUIRED_ENV.length; i++) {
            values[i] = System.getenv(REQUIRED_ENV[i]);
            if (values[i] == null || values[i].isEmpty()) {
                return "Missing required Android signing environment variables.";
            }
        }

        byte[] keystoreBytes;
        try {
            keystoreBytes = Base64.getDecoder().decode(values[0]);
        } catch (IllegalArgumentException ignored) {
            return "Invalid Android keystore data.";
        }
        if (keystoreBytes.length == 0) {
            return "Invalid Android keystore data.";
        }

        Path androidDirectory = Path.of("android");
        Path appDirectory = androidDirectory.resolve("app");
        Path propertiesFile = androidDirectory.resolve("local.properties");
        Path keystoreFile = appDirectory.resolve("keystore.jks");
        if (Files.exists(keystoreFile)) {
            return "Android keystore already exists.";
        }
        if (!Files.isDirectory(androidDirectory) || !Files.isDirectory(appDirectory)) {
            return "Unable to prepare Android signing material.";
        }

        Properties properties = new Properties();
        try {
            if (Files.exists(propertiesFile)) {
                try (InputStream input = Files.newInputStream(propertiesFile)) {
                    properties.load(input);
                }
            }
            properties.setProperty("storePassword", values[1]);
            properties.setProperty("keyAlias", values[2]);
            properties.setProperty("keyPassword", values[3]);
        } catch (IOException | IllegalArgumentException ignored) {
            return "Unable to prepare Android signing material.";
        }

        Path stagedKeystore = null;
        Path stagedProperties = null;
        boolean installedKeystore = false;
        try {
            stagedKeystore = Files.createTempFile(appDirectory, ".keystore-", ".tmp");
            stagedProperties = Files.createTempFile(androidDirectory, ".local-properties-", ".tmp");
            Files.write(stagedKeystore, keystoreBytes);
            try (OutputStream output = Files.newOutputStream(stagedProperties)) {
                properties.store(output, null);
            }
            Files.move(stagedKeystore, keystoreFile, StandardCopyOption.ATOMIC_MOVE);
            stagedKeystore = null;
            installedKeystore = true;
            Files.move(
                stagedProperties,
                propertiesFile,
                StandardCopyOption.ATOMIC_MOVE,
                StandardCopyOption.REPLACE_EXISTING);
            stagedProperties = null;
            return null;
        } catch (IOException | UnsupportedOperationException ignored) {
            if (installedKeystore) {
                deleteQuietly(keystoreFile);
            }
            return "Unable to prepare Android signing material.";
        } finally {
            deleteQuietly(stagedKeystore);
            deleteQuietly(stagedProperties);
        }
    }

    private static void deleteQuietly(Path path) {
        if (path == null) {
            return;
        }
        try {
            Files.deleteIfExists(path);
        } catch (IOException ignored) {
            // Temporary files are best-effort cleanup after a failed write.
        }
    }

    private static void fail(String message) {
        System.err.println(message);
        System.exit(1);
    }
}
