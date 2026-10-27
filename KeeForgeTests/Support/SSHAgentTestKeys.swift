#if os(macOS)
import Foundation

/// Throwaway SSH keys generated for the agent tests with Python's
/// `cryptography` package, an implementation independent of KeeForge's
/// parser. They protect nothing.
enum SSHAgentTestKeys {
    struct Fixture {
        let privateKeyFile: String
        /// Base64 SSH wire-format public key, as `ssh-add -L` prints it.
        let publicKeyBlob: String
        let fingerprint: String
        let comment: String

        var fileData: Data { Data(privateKeyFile.utf8) }
        var publicKeyData: Data { Data(base64Encoded: publicKeyBlob) ?? Data() }
    }

    /// Written field by field to PROTOCOL.key, with a comment; `cryptography` reads it back.
    static let ed25519 = Fixture(
        privateKeyFile: """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        QyNTUxOQAAACAt20X5vsEtXHnSLDKx32bHpoSCQAYA1h+zxv8j7l4b7wAAAJhe7RI0Xu0S
        NAAAAAtzc2gtZWQyNTUxOQAAACAt20X5vsEtXHnSLDKx32bHpoSCQAYA1h+zxv8j7l4b7w
        AAAECsu7onZTDAcFZUe+ojdBICp99BIHS4gQYMvnMQqiRPQi3bRfm+wS1cedIsMrHfZsem
        hIJABgDWH7PG/yPuXhvvAAAAFWVkMjU1MTlAa2VlZm9yZ2UudGVzdA==
        -----END OPENSSH PRIVATE KEY-----
        """,
        publicKeyBlob: "AAAAC3NzaC1lZDI1NTE5AAAAIC3bRfm+wS1cedIsMrHfZsemhIJABgDWH7PG/yPuXhvv",
        fingerprint: "SHA256:fMNWkDzeu6aLbsFLiqPxTgIxtyvSk6aZK2Dk6pVsi8g",
        comment: "ed25519@keeforge.test"
    )

    /// The same key as serialized by `cryptography` itself: no comment, random check integers.
    static let ed25519WrittenByCryptography = Fixture(
        privateKeyFile: """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZWQyNTUx
        OQAAACAt20X5vsEtXHnSLDKx32bHpoSCQAYA1h+zxv8j7l4b7wAAAIjqXvw/6l78PwAAAAtzc2gt
        ZWQyNTUxOQAAACAt20X5vsEtXHnSLDKx32bHpoSCQAYA1h+zxv8j7l4b7wAAAECsu7onZTDAcFZU
        e+ojdBICp99BIHS4gQYMvnMQqiRPQi3bRfm+wS1cedIsMrHfZsemhIJABgDWH7PG/yPuXhvvAAAA
        AAECAwQF
        -----END OPENSSH PRIVATE KEY-----
        """,
        publicKeyBlob: "AAAAC3NzaC1lZDI1NTE5AAAAIC3bRfm+wS1cedIsMrHfZsemhIJABgDWH7PG/yPuXhvv",
        fingerprint: "SHA256:fMNWkDzeu6aLbsFLiqPxTgIxtyvSk6aZK2Dk6pVsi8g",
        comment: ""
    )

    /// The Ed25519 public key in an `aes256-ctr`/`bcrypt` container around random bytes.
    static let ed25519PassphraseProtected = Fixture(
        privateKeyFile: """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABBNHdftZZ
        awhBW2n8M6PQBmAAAAEAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIC3bRfm+wS1cedIs
        MrHfZsemhIJABgDWH7PG/yPuXhvvAAAAoOFo0KX/kaloyw37Mjh+bgvJ5uZ6shL6ehZtGn
        j3HFx2THS6xoEv916B0CKtI2nvLEKf2qFbO9Cg9MVkn4jwuBEVZB75zCAUJS4T13YKi+ai
        eT58N+WNp5NgnmhSdbJIsHbcWWs4Irbq9yucayiUEVv3XS4kB/I/6VW42AzJ3scdL4ANva
        lXem/P6V0iFGYlynFQGslk7FruX0zopftlZ84=
        -----END OPENSSH PRIVATE KEY-----
        """,
        publicKeyBlob: "AAAAC3NzaC1lZDI1NTE5AAAAIC3bRfm+wS1cedIsMrHfZsemhIJABgDWH7PG/yPuXhvv",
        fingerprint: "SHA256:fMNWkDzeu6aLbsFLiqPxTgIxtyvSk6aZK2Dk6pVsi8g",
        comment: ""
    )

    /// ECDSA on NIST P-256.
    static let ecdsaP256 = Fixture(
        privateKeyFile: """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAaAAAABNlY2RzYS
        1zaGEyLW5pc3RwMjU2AAAACG5pc3RwMjU2AAAAQQTic9YluCmZvS7dM37WiK2IABIKUTIL
        Pa+eL11gXm5vSr2c2Jb/1iDcmnsL4pkGLCbJlc/1A3OuFQFfYnah1AAoAAAAsF7tEjRe7R
        I0AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBOJz1iW4KZm9Lt0z
        ftaIrYgAEgpRMgs9r54vXWBebm9KvZzYlv/WINyaewvimQYsJsmVz/UDc64VAV9idqHUAC
        gAAAAhAMy9MqUcl9M3+0qBksVZ+lgjTBjqqdxLkN0afehvjLFZAAAAFm5pc3RwMjU2QGtl
        ZWZvcmdlLnRlc3QB
        -----END OPENSSH PRIVATE KEY-----
        """,
        publicKeyBlob: "AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBOJz1iW4KZm9Lt0zftaIrYgAEgpRMgs9r54vXWBebm9KvZzYlv/WINyaewvimQYsJsmVz/UDc64VAV9idqHUACg=",
        fingerprint: "SHA256:fe9P+OMW4reizsegvWPra3YkFcDWNrRogcQkCn5+3SA",
        comment: "nistp256@keeforge.test"
    )

    /// ECDSA on NIST P-384.
    static let ecdsaP384 = Fixture(
        privateKeyFile: """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAiAAAABNlY2RzYS
        1zaGEyLW5pc3RwMzg0AAAACG5pc3RwMzg0AAAAYQTJnQofPqnoXhlR8RX2f9NkCXwjOMUg
        ExUih2rVH6VCtKmlBnacJt/25VQ1qeTi5i3xhuYoVz0kwTPO28OPucRcxHwhJxl3A10Mk7
        TMyXGmflbY5W72RTsfyyUc8FZWSq0AAADgXu0SNF7tEjQAAAATZWNkc2Etc2hhMi1uaXN0
        cDM4NAAAAAhuaXN0cDM4NAAAAGEEyZ0KHz6p6F4ZUfEV9n/TZAl8IzjFIBMVIodq1R+lQr
        SppQZ2nCbf9uVUNank4uYt8YbmKFc9JMEzztvDj7nEXMR8IScZdwNdDJO0zMlxpn5W2OVu
        9kU7H8slHPBWVkqtAAAAMFtfTRm7YVCIAJvxYRkepav+OyzilDYMTHnb5fIjbjPV7Pzb6q
        gokGuiq7EcSSjn3gAAABZuaXN0cDM4NEBrZWVmb3JnZS50ZXN0AQI=
        -----END OPENSSH PRIVATE KEY-----
        """,
        publicKeyBlob: "AAAAE2VjZHNhLXNoYTItbmlzdHAzODQAAAAIbmlzdHAzODQAAABhBMmdCh8+qeheGVHxFfZ/02QJfCM4xSATFSKHatUfpUK0qaUGdpwm3/blVDWp5OLmLfGG5ihXPSTBM87bw4+5xFzEfCEnGXcDXQyTtMzJcaZ+VtjlbvZFOx/LJRzwVlZKrQ==",
        fingerprint: "SHA256:sWAU5kkt7AQrTo/YSB10Xly3PI5bcmQB8PsxydSoACM",
        comment: "nistp384@keeforge.test"
    )

    /// ECDSA on NIST P-521.
    static let ecdsaP521 = Fixture(
        privateKeyFile: """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAArAAAABNlY2RzYS
        1zaGEyLW5pc3RwNTIxAAAACG5pc3RwNTIxAAAAhQQBe2aBB4iEtSvzTioDVfb8xAb35070
        glCuAXY0oPxnwSdybeoKw2IuTRVFj6aj1kczzs5zSgNIrfLXttdVuQJAMzkAfPXpTbpQ4O
        kzf3/k3NY02QYOZWmCdP1k3iXJ87xTMXObuBJWA+CedepFf0cjoomqaMSHFljRx6UYIM56
        gN+DRhAAAAEYXu0SNF7tEjQAAAATZWNkc2Etc2hhMi1uaXN0cDUyMQAAAAhuaXN0cDUyMQ
        AAAIUEAXtmgQeIhLUr804qA1X2/MQG9+dO9IJQrgF2NKD8Z8Encm3qCsNiLk0VRY+mo9ZH
        M87Oc0oDSK3y17bXVbkCQDM5AHz16U26UODpM39/5NzWNNkGDmVpgnT9ZN4lyfO8UzFzm7
        gSVgPgnnXqRX9HI6KJqmjEhxZY0celGCDOeoDfg0YQAAAAQgCdFl0sx/m2SssRJchzBrn2
        +nrUWurybmOi3R+eue6yjJaFiI0trhNGm8aGaOJoJ/XG+16CVTgVQ9KK9sx+wT3OeQAAAB
        ZuaXN0cDUyMUBrZWVmb3JnZS50ZXN0AQIDBA==
        -----END OPENSSH PRIVATE KEY-----
        """,
        publicKeyBlob: "AAAAE2VjZHNhLXNoYTItbmlzdHA1MjEAAAAIbmlzdHA1MjEAAACFBAF7ZoEHiIS1K/NOKgNV9vzEBvfnTvSCUK4BdjSg/GfBJ3Jt6grDYi5NFUWPpqPWRzPOznNKA0it8te211W5AkAzOQB89elNulDg6TN/f+Tc1jTZBg5laYJ0/WTeJcnzvFMxc5u4ElYD4J516kV/RyOiiapoxIcWWNHHpRggznqA34NGEA==",
        fingerprint: "SHA256:rPWVtX8PUaaUrDa8BQ2OnZoGwKXYlUeYpNiVk7AHdQA",
        comment: "nistp521@keeforge.test"
    )

    /// RSA 2048, written field by field.
    static let rsa = Fixture(
        privateKeyFile: """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAABFwAAAAdzc2gtcn
        NhAAAAAwEAAQAAAQEAyn1bdOH1evoqGX2fatO+Sda8jN9SxUVp4NtW07bQSLSFc6P/e8CN
        VDHTlOFHKn7K0ZPbNahuByGSy3Qu3CmwWP/DDH5/ScKLqlI7+J/TFm5VFbjE3J+mYA3Rf9
        04Nd7tlGqPjiS++Z0TdvyQJLq3CjCPgKfPViK2BKCvKfA1Iw8jXVhx+Z3UChT7ECj5DLyV
        XYDq/iSNWNZvCgcQOjPRkYBUBAmRVmJh/6aToMOJjJz+wI5zY3SbR9FyhHOjfiWIdUUgEr
        ATUkhqP2tV6p6uxlfIOsNsurEBzOkvrT9Zu2d/dpV+uejlnYHucn4pWodLrpmW7QhDcp2M
        hD0/aMU8HQAAA8he7RI0Xu0SNAAAAAdzc2gtcnNhAAABAQDKfVt04fV6+ioZfZ9q075J1r
        yM31LFRWng21bTttBItIVzo/97wI1UMdOU4UcqfsrRk9s1qG4HIZLLdC7cKbBY/8MMfn9J
        wouqUjv4n9MWblUVuMTcn6ZgDdF/3Tg13u2Uao+OJL75nRN2/JAkurcKMI+Ap89WIrYEoK
        8p8DUjDyNdWHH5ndQKFPsQKPkMvJVdgOr+JI1Y1m8KBxA6M9GRgFQECZFWYmH/ppOgw4mM
        nP7AjnNjdJtH0XKEc6N+JYh1RSASsBNSSGo/a1Xqnq7GV8g6w2y6sQHM6S+tP1m7Z392lX
        656OWdge5yfilah0uumZbtCENynYyEPT9oxTwdAAAAAwEAAQAAAQAq32fh04XaR+VqCEMc
        p0B++cxqN06bHhtQ1KAJq4dmHXK0DWEmnppN3U7jEt+yi639ucSME+FX+S/PjAXv75O7BE
        wT9SSWRW603Tx9Y7mZ4jp5oulrnRHo/IQDAp/IKC89YWKLwhP9XdilNMyAOlhO/AEmSGGJ
        50eKq0rrIkTd6xHzoAa0V4N45l3pPpDcgc1z3UotklptByQNPWfEferT6VIlMuZTC09MSQ
        TEGsxP5xmUfMm2hxdRHzx7DeDVElHEmnsdqVcFFW53AfnphibqaVJGKPQ3q73jZeZGd+cb
        3XEvGC2s/DsvqeQCFK3+6ZA7AO9MewNRBYDnjY3w5J6BAAAAgQDNDtiJtd5B11Nm/kywib
        Y4/PEtSZd77RNvbwdLAoYC4v0sr1J1yg4ROTDn3CjP6EgIyD6yHaOlvKhI7ihZg0l4UXWW
        KwNQQ1mJ8fIuG241YUWO/DhWGg92PUSnzoK/QjKEcI7MciWVpimKR2yAKl0Df38kdL8W3t
        NoutV1EIWnrgAAAIEA9LxQhvj8cOr/VEM4auD7T+huIWghliKF2NG6zXZYhe0uc3/LTKBM
        k4Jil9MhjoWMIUvGdE+mdT58v/9raouZZxyA8TzePetEibGOgi7xmSowo+N8Nl6SPT38Jk
        GyWFGrfMJjaMB01rRMLL4a5chWyHRg0hVEpfXiB+IE5C+9x+kAAACBANPPQ8w4+FKoPQHM
        fPOCtj1PF2YhG7ACjfcudMGo9q+//aMlLJDoPJSRCYR0ICo1IC/337fgWrJkt7PhKRBg9m
        spwN4GhFWwlPgpMjFQ9xgb0QJBq4gdZNh/zTMbvJM9OZfDTH2jE4d/Eh53o/tn1qTxJEjp
        lIlp+RpGAMKRBWYVAAAAEXJzYUBrZWVmb3JnZS50ZXN0AQ==
        -----END OPENSSH PRIVATE KEY-----
        """,
        publicKeyBlob: "AAAAB3NzaC1yc2EAAAADAQABAAABAQDKfVt04fV6+ioZfZ9q075J1ryM31LFRWng21bTttBItIVzo/97wI1UMdOU4UcqfsrRk9s1qG4HIZLLdC7cKbBY/8MMfn9JwouqUjv4n9MWblUVuMTcn6ZgDdF/3Tg13u2Uao+OJL75nRN2/JAkurcKMI+Ap89WIrYEoK8p8DUjDyNdWHH5ndQKFPsQKPkMvJVdgOr+JI1Y1m8KBxA6M9GRgFQECZFWYmH/ppOgw4mMnP7AjnNjdJtH0XKEc6N+JYh1RSASsBNSSGo/a1Xqnq7GV8g6w2y6sQHM6S+tP1m7Z392lX656OWdge5yfilah0uumZbtCENynYyEPT9oxTwd",
        fingerprint: "SHA256:1V8UmT1485mbQDMCo/nM+wq2UxPu9aBQjsUH6P273MY",
        comment: "rsa@keeforge.test"
    )

    /// The same RSA key as serialized by `cryptography` itself.
    static let rsaWrittenByCryptography = Fixture(
        privateKeyFile: """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAABFwAAAAdzc2gtcnNhAAAA
        AwEAAQAAAQEAyn1bdOH1evoqGX2fatO+Sda8jN9SxUVp4NtW07bQSLSFc6P/e8CNVDHTlOFHKn7K
        0ZPbNahuByGSy3Qu3CmwWP/DDH5/ScKLqlI7+J/TFm5VFbjE3J+mYA3Rf904Nd7tlGqPjiS++Z0T
        dvyQJLq3CjCPgKfPViK2BKCvKfA1Iw8jXVhx+Z3UChT7ECj5DLyVXYDq/iSNWNZvCgcQOjPRkYBU
        BAmRVmJh/6aToMOJjJz+wI5zY3SbR9FyhHOjfiWIdUUgErATUkhqP2tV6p6uxlfIOsNsurEBzOkv
        rT9Zu2d/dpV+uejlnYHucn4pWodLrpmW7QhDcp2MhD0/aMU8HQAAA7jVA6Df1QOg3wAAAAdzc2gt
        cnNhAAABAQDKfVt04fV6+ioZfZ9q075J1ryM31LFRWng21bTttBItIVzo/97wI1UMdOU4UcqfsrR
        k9s1qG4HIZLLdC7cKbBY/8MMfn9JwouqUjv4n9MWblUVuMTcn6ZgDdF/3Tg13u2Uao+OJL75nRN2
        /JAkurcKMI+Ap89WIrYEoK8p8DUjDyNdWHH5ndQKFPsQKPkMvJVdgOr+JI1Y1m8KBxA6M9GRgFQE
        CZFWYmH/ppOgw4mMnP7AjnNjdJtH0XKEc6N+JYh1RSASsBNSSGo/a1Xqnq7GV8g6w2y6sQHM6S+t
        P1m7Z392lX656OWdge5yfilah0uumZbtCENynYyEPT9oxTwdAAAAAwEAAQAAAQAq32fh04XaR+Vq
        CEMcp0B++cxqN06bHhtQ1KAJq4dmHXK0DWEmnppN3U7jEt+yi639ucSME+FX+S/PjAXv75O7BEwT
        9SSWRW603Tx9Y7mZ4jp5oulrnRHo/IQDAp/IKC89YWKLwhP9XdilNMyAOlhO/AEmSGGJ50eKq0rr
        IkTd6xHzoAa0V4N45l3pPpDcgc1z3UotklptByQNPWfEferT6VIlMuZTC09MSQTEGsxP5xmUfMm2
        hxdRHzx7DeDVElHEmnsdqVcFFW53AfnphibqaVJGKPQ3q73jZeZGd+cb3XEvGC2s/DsvqeQCFK3+
        6ZA7AO9MewNRBYDnjY3w5J6BAAAAgQDNDtiJtd5B11Nm/kywibY4/PEtSZd77RNvbwdLAoYC4v0s
        r1J1yg4ROTDn3CjP6EgIyD6yHaOlvKhI7ihZg0l4UXWWKwNQQ1mJ8fIuG241YUWO/DhWGg92PUSn
        zoK/QjKEcI7MciWVpimKR2yAKl0Df38kdL8W3tNoutV1EIWnrgAAAIEA9LxQhvj8cOr/VEM4auD7
        T+huIWghliKF2NG6zXZYhe0uc3/LTKBMk4Jil9MhjoWMIUvGdE+mdT58v/9raouZZxyA8TzePetE
        ibGOgi7xmSowo+N8Nl6SPT38JkGyWFGrfMJjaMB01rRMLL4a5chWyHRg0hVEpfXiB+IE5C+9x+kA
        AACBANPPQ8w4+FKoPQHMfPOCtj1PF2YhG7ACjfcudMGo9q+//aMlLJDoPJSRCYR0ICo1IC/337fg
        WrJkt7PhKRBg9mspwN4GhFWwlPgpMjFQ9xgb0QJBq4gdZNh/zTMbvJM9OZfDTH2jE4d/Eh53o/tn
        1qTxJEjplIlp+RpGAMKRBWYVAAAAAAEC
        -----END OPENSSH PRIVATE KEY-----
        """,
        publicKeyBlob: "AAAAB3NzaC1yc2EAAAADAQABAAABAQDKfVt04fV6+ioZfZ9q075J1ryM31LFRWng21bTttBItIVzo/97wI1UMdOU4UcqfsrRk9s1qG4HIZLLdC7cKbBY/8MMfn9JwouqUjv4n9MWblUVuMTcn6ZgDdF/3Tg13u2Uao+OJL75nRN2/JAkurcKMI+Ap89WIrYEoK8p8DUjDyNdWHH5ndQKFPsQKPkMvJVdgOr+JI1Y1m8KBxA6M9GRgFQECZFWYmH/ppOgw4mMnP7AjnNjdJtH0XKEc6N+JYh1RSASsBNSSGo/a1Xqnq7GV8g6w2y6sQHM6S+tP1m7Z392lX656OWdge5yfilah0uumZbtCENynYyEPT9oxTwd",
        fingerprint: "SHA256:1V8UmT1485mbQDMCo/nM+wq2UxPu9aBQjsUH6P273MY",
        comment: ""
    )

    /// The RSA key in the legacy PKCS#1 PEM format, which the agent does not read.
    static let rsaTraditionalPEM = """
        -----BEGIN RSA PRIVATE KEY-----
        MIIEowIBAAKCAQEAyn1bdOH1evoqGX2fatO+Sda8jN9SxUVp4NtW07bQSLSFc6P/
        e8CNVDHTlOFHKn7K0ZPbNahuByGSy3Qu3CmwWP/DDH5/ScKLqlI7+J/TFm5VFbjE
        3J+mYA3Rf904Nd7tlGqPjiS++Z0TdvyQJLq3CjCPgKfPViK2BKCvKfA1Iw8jXVhx
        +Z3UChT7ECj5DLyVXYDq/iSNWNZvCgcQOjPRkYBUBAmRVmJh/6aToMOJjJz+wI5z
        Y3SbR9FyhHOjfiWIdUUgErATUkhqP2tV6p6uxlfIOsNsurEBzOkvrT9Zu2d/dpV+
        uejlnYHucn4pWodLrpmW7QhDcp2MhD0/aMU8HQIDAQABAoIBACrfZ+HThdpH5WoI
        QxynQH75zGo3TpseG1DUoAmrh2YdcrQNYSaemk3dTuMS37KLrf25xIwT4Vf5L8+M
        Be/vk7sETBP1JJZFbrTdPH1juZniOnmi6WudEej8hAMCn8goLz1hYovCE/1d2KU0
        zIA6WE78ASZIYYnnR4qrSusiRN3rEfOgBrRXg3jmXek+kNyBzXPdSi2SWm0HJA09
        Z8R96tPpUiUy5lMLT0xJBMQazE/nGZR8ybaHF1EfPHsN4NUSUcSaex2pVwUVbncB
        +emGJuppUkYo9DerveNl5kZ35xvdcS8YLaz8Oy+p5AIUrf7pkDsA70x7A1EFgOeN
        jfDknoECgYEA9LxQhvj8cOr/VEM4auD7T+huIWghliKF2NG6zXZYhe0uc3/LTKBM
        k4Jil9MhjoWMIUvGdE+mdT58v/9raouZZxyA8TzePetEibGOgi7xmSowo+N8Nl6S
        PT38JkGyWFGrfMJjaMB01rRMLL4a5chWyHRg0hVEpfXiB+IE5C+9x+kCgYEA089D
        zDj4Uqg9Acx884K2PU8XZiEbsAKN9y50waj2r7/9oyUskOg8lJEJhHQgKjUgL/ff
        t+BasmS3s+EpEGD2aynA3gaEVbCU+CkyMVD3GBvRAkGriB1k2H/NMxu8kz05l8NM
        faMTh38SHnej+2fWpPEkSOmUiWn5GkYAwpEFZhUCgYBXNCKddWq98X45UBpyOuhR
        eMiFLs2I6ZQ3xcOCIoE4d2Lt1MNj8lpW1Ua8QobaecuMsattFlSBwlpBL4ne1Q88
        JnPrgXzPI12wkovs5z0/DkF2pEBGPzxshgGqwA4EWlV4hutVD/6R4nyiFLsQ1WnW
        02EMeneTiyGXHXoQtNIywQKBgF/2O4U/GmJ4jotOFh5NTjugpb1DqsOnpKIkjglf
        f8RIe6V6piJQ1YGJ5IH6CsiUoSyaZOVt5CmGsCPzEyO0inAqzpLI6RPZmOSF5ZOq
        Vwi5MYyQLCLTDml4HYPWQS2EQ5+agAE77REqZQ8grU6t0PWRuxq9mOpY9N8OcDG2
        enexAoGBAM0O2Im13kHXU2b+TLCJtjj88S1Jl3vtE29vB0sChgLi/SyvUnXKDhE5
        MOfcKM/oSAjIPrIdo6W8qEjuKFmDSXhRdZYrA1BDWYnx8i4bbjVhRY78OFYaD3Y9
        RKfOgr9CMoRwjsxyJZWmKYpHbIAqXQN/fyR0vxbe02i61XUQhaeu
        -----END RSA PRIVATE KEY-----
        """

    static let message = Data("KeeForge SSH agent test message".utf8)

    /// `rsa`'s deterministic PKCS #1 v1.5 signature blobs over `message`,
    /// computed by `cryptography`.
    static let rsaSHA256SignatureBlob = "AAAADHJzYS1zaGEyLTI1NgAAAQA6SLBeE0i4UqDDXdzO6z7o3muPWkyqnUo4AjSiuxNv9T1Ff+5oJ3h9mPeiY55qfaQZJ5JqFUU9Myw8vDLILrocyrK1QlUOjFp7VDlTDLl5Te3LsU/EvYxruWo3mvmM9TEWyLvHHmeAmJbZ2SS/ClQkgk5uUzQbUGpfm6zWeVxpE3BXYVRgiwCiLTGdpoRk4wqCqqw4J4Zr+J5ZoSf4OJUDeTHLkcsIJAlLXnBL4E3ZPwCWSflgZrsFb7/lQLsjADtcjGziGd4P6XiPEvRtCFPPIn5OWQefaAaOlSydfJ1thlkBSmczzFAMOZsBrDh5tpI1uvo5n3H19Wxm/H2nvCuK"
    static let rsaSHA512SignatureBlob = "AAAADHJzYS1zaGEyLTUxMgAAAQBvVjJ8JL6Js34wu0WeSI2E3t0QIDqdgUJrcv4ckXQbCPPPpEOhgbiISIihwmApf1RfGYqp8doaH5wdNFT+rHZ0WLJI8dazCp+r7P96Nu6FztOYhinDoiMHTeBvIS5LlSOORM5fTLaXI7TTxy+zhsyh8Rc39DFZ0upRbAwlBZXlFNY03HYLBHgORI8ghisoQUlQQ88O0LKlulEkTcrBg57otFuzAkRUdHm0JN+yO68ea5D9unCPwbPmCyu5tt3cExa9v1qMcIE34lWhifpeCUa+De65w8fr3IUdDOJRbMKyInaF61d/7LQWq2Ba8xST8hl2weo+QDMQeX49R7PMxsU2"
}
#endif
