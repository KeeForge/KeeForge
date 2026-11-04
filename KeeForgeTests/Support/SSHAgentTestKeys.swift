#if os(macOS)
import Foundation

/// Throwaway SSH keys generated for the agent tests with Python's
/// `cryptography` package or `ssh-keygen`, implementations independent of
/// KeeForge's parser, with reference signatures from `cryptography`. They
/// protect nothing.
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

    /// RSA 1024, written by `ssh-keygen`.
    static let rsa1024 = Fixture(
        privateKeyFile: """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAlwAAAAdzc2gtcn
        NhAAAAAwEAAQAAAIEAxro93MmiNGW4F9vZgCsbl+hJbrxXYLsJKu7hYIhVY7xTNhrUKoF4
        EGPUk73Gik03SQEo540XMIoT+xEEfSIfpRm0vR9ASE5MIDiQhAtMlza7XY4yXvGJCNW93d
        cVRTPRvWidWalznnjhMYrVzd5C/zhxdmMr5cDUPv/JyZvhKe0AAAIQcXVCYXF1QmEAAAAH
        c3NoLXJzYQAAAIEAxro93MmiNGW4F9vZgCsbl+hJbrxXYLsJKu7hYIhVY7xTNhrUKoF4EG
        PUk73Gik03SQEo540XMIoT+xEEfSIfpRm0vR9ASE5MIDiQhAtMlza7XY4yXvGJCNW93dcV
        RTPRvWidWalznnjhMYrVzd5C/zhxdmMr5cDUPv/JyZvhKe0AAAADAQABAAAAgF1QFD44+4
        4o+TFSzSVOmI1SyDBUBZ9pE5vyQSenvJixVE1Ceb9fvbXMeoPJB5HnQf9oqQFZEbt8CnfI
        fNgZDswNVlgudzPKB8rhekLtSEXcd8WiaIc5cR3jDaeKP0PW+XVpI08FTwCXPRAe7Sg3Ak
        xuG3JxaDj8kfJLSDem0W0NAAAAQQDOscSFdt/sIsvzQuqNHTixOxU7lmFDpoxCl8Yv/6Yd
        YPv6u4z58+I9IqqhF/fUcV3lnRejJJgveVqhyfW0NoPdAAAAQQD7sw/bjPvPmu1kIxxJAk
        ahEDGP+2m0lpjeIzGYOW0rVBempUnE/e2+5H4Nn3CipKrgORp0eX+LpTHKQBQc73XfAAAA
        QQDKH3q6bPnxls+9e4CrdhrN+Xxi2zpE7A3RhhHyJqwhxQvNOhaosAperkzQ+3COdoLcaO
        dzhT+1kBf41H9FwCGzAAAAFXJzYTEwMjRAa2VlZm9yZ2UudGVzdAECAwQF
        -----END OPENSSH PRIVATE KEY-----
        """,
        publicKeyBlob: "AAAAB3NzaC1yc2EAAAADAQABAAAAgQDGuj3cyaI0ZbgX29mAKxuX6EluvFdguwkq7uFgiFVjvFM2GtQqgXgQY9STvcaKTTdJASjnjRcwihP7EQR9Ih+lGbS9H0BITkwgOJCEC0yXNrtdjjJe8YkI1b3d1xVFM9G9aJ1ZqXOeeOExitXN3kL/OHF2YyvlwNQ+/8nJm+Ep7Q==",
        fingerprint: "SHA256:OODeH5OVVz9GKCM3SttQrQqTXDNNM/VbqsnkSQu1hcM",
        comment: "rsa1024@keeforge.test"
    )

    /// RSA 3072, written by `ssh-keygen`.
    static let rsa3072 = Fixture(
        privateKeyFile: """
        -----BEGIN OPENSSH PRIVATE KEY-----
        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
        -----END OPENSSH PRIVATE KEY-----
        """,
        publicKeyBlob: "AAAAB3NzaC1yc2EAAAADAQABAAABgQDW4Ex9+CD6mNXbr6/MRAmLEMtny4is/e79JnYhlSyCiA8REj4Mg/pkXlxw92OTfXUA3xT0sVKZ15IMv5tZsWZK9+gOyXu7ZWxqP+Tms5FGVEooD9KKU5WkP9rPeIsFq3MXm5XkAKvFW91BIUiThoN2Ln0+p3oz24W4gvBVy9VWjOHbDmd0LtPz98RQMly4sJgAaHseYzU7hoRvD8gs6smpxyKuI0TcPP614ewPYlf9x+/w2j1OdUhjtkoxb7LO5511Fq18nuFkNywzmC4y3Uc+++SpKEP97WNffoEGQz5tjggYwV272z6A+Ub0A5HFk+Nz07w8HK6pYIOVHLK3+laLbxIn2lvlgq5x5nQiwrVyCUCdaHflBGhnRbq3aowrl8rdlQRqYkRIxmOCvt3sfnk9LmipkWdiMs1NToH/xXYTE4QIkdj5iAQ4oeyt498/cNgLHYgM4D/EkuQOtwU6FLRl7+2k5Va1xxJFmXihB7a0CF3IWKjaEMieCkU8ykHI8EU=",
        fingerprint: "SHA256:8GWeso9vtrdxu3jcsmCjKpM/Qy32T2VSFvoW5GeQKc0",
        comment: "rsa3072@keeforge.test"
    )

    /// `rsa3072`'s PKCS #1 v1.5 signature blobs over `message`.
    static let rsa3072SHA256SignatureBlob = "AAAADHJzYS1zaGEyLTI1NgAAAYCTXBRYi7rvHTqWvn+78Fq0L7JkLeNSg8lhIi4FJcp94kQTze/Yv7+GTc399U55m4K+4ck80w57X6tWIN0KlNNwrFJiTL/47KeRZ3rAklbUepiKFyuT2jBeOgLObUC5Zqz1dA7KKgvrvSNva+NfsQ+7ADs/W6K6a14EMaxaZSRz6ti2+5jxr+vTlVemyhdPC+Fd1xSmsTsS5xVO3V/VED4Bqq+U8BToaNhFEN4sQZkojdBdLpNB1lLivLwYNFd8xGEChw+r6ckIO9PXtZ8OlBRphG4tdKZ326XCfypvjWeHSjZTEJRych0CYE/HSGl0BHoV+CZsD7C/bN7Z8btju2HwceIzH4/X98pUKQRo3R4ReFwqXAA0VDoUvJBWIO46MVLDdiJAQd3NZ2OvBRq/4ZemyQny8CZPPpkptP0ebgURCO3MHcgJdlu9RKphkGrghF1zJ8GpBNldT+lAwSBxhiq6aTfXoVQeIMvUSrkqno7o8FU6rwcSy7u3dUGc1sJw55U="
    static let rsa3072SHA512SignatureBlob = "AAAADHJzYS1zaGEyLTUxMgAAAYBPt7+sekulkjxL0slABqe7NEt3QR8HIto1tVn4M5tRjrK96e/C9ZDfvc8OZCEeDZefY5mA4leyJZHJC5k8mnvgd5HQooGN2IVRrCkw0wXw6cPaq+JIYe7NbTOTlZEocwgdhMBamm8S/a5eGpJ5I8qpAC8qBHkXItL3poyfVqgU5WwoTy3sojOBGBKbIXsK8s/MchCKlxlt8vFRj16urrOBNyZ7i6QN0mF1Ba2Qq5ZT5kVVnW4MqOHgPc5+Bqwnj20wDhfHeeioSVP67mtB1ESbAgwCuI7eBGqf7+yraI+znG9LDidKtBvAqdRRJcrptUPtPBZWXT3HNfawzWBUfCmuUrZIa+XigL4PhFZUeVqPAd1DrXy39BcO0rJizVeKgo13ntJZFqdc0bEjiinB6mTKNE0g+kPpL7fH04CvKzDyf2YyzGf+VRbwu9vYGNd8/2pQeD35bogi6dRKCj0Yf16MZVSlORfshLso4jJmLAv1KgWCKnNalNX13nzOrtmFjdw="

    /// RSA 4096, written by `ssh-keygen`.
    static let rsa4096 = Fixture(
        privateKeyFile: """
        -----BEGIN OPENSSH PRIVATE KEY-----
        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
        -----END OPENSSH PRIVATE KEY-----
        """,
        publicKeyBlob: "AAAAB3NzaC1yc2EAAAADAQABAAACAQDbB2SweMe8cnzDTS+1MM0vHkRN/mGe/dsCwYBTZsHsQ7+XAGuOxzjT/Wshj9vP1Pykp4ZpEkvVlvMore671tTgLq49Kh/nH3m7Y0q58OkL9JBBg+AjHPqPab/H2h0AbKRT24MCoGB1ewwmvKNiqO9i+mFAkkMeUMYynpmzXQ1b6bROLEbjmgFcdao3ocwU7wiqlnSOWoEg5UyN0Q0C5IxlP9vmlgN7bUYITQfpkNHCngskhxmGM36cjKwQB2bgJFhe+mhXdgsMRrz3otDcgzQiygJTr5tRA64pai9KOUD52NdbqMxZUhsepJ0chVOyx6A1nKMSdwzqj2A4H5GSGECDhWkQUqCqE4zh7UsE9NCkq9eswiKuBJcAcXvDxiD5fvsq0unCeMEKK8yX79ph+o4CUw/r2gIDCh/pTptznM62rmPbPq0Q2oyVjeKvy+FL49B7OhMCquvT+lVKwz6kyjXwDNzWjSu2Gc7cEoj3Ylgv3baKbxf+mx0EiiTGFk9KLhUS5lyKteJEthxJnS4kdYcPUIyLeGovib4CPUDPjTZ9ORmqycBdab3IbUtuUoB1xzz/6vy3yB84Z2QcvXx7KapcHpL5tQ3oXner70U0Arfc8icGyiQINuNxeadi6e+Hy7pfqi/bR/wIYTthYh8r+lK8sjkw+t5JQWyAMlWw9uS+BQ==",
        fingerprint: "SHA256:W2sn6WdHIYAnsUKepo89cYefUNFzA8AUZUanUiDvDh4",
        comment: "rsa4096@keeforge.test"
    )

    /// `rsa4096`'s PKCS #1 v1.5 signature blobs over `message`.
    static let rsa4096SHA256SignatureBlob = "AAAADHJzYS1zaGEyLTI1NgAAAgAouiBSJvk4cXTDUZE8PhFfIm6UmL18Sk3WZtKbmqKqPOpJlmrmNoz0inJEHnFz56215FKJtHhnKc2ZauVVYSUCO6G0c5IpfrJ4Q6l+6YHJIMpVGpqcS/PYxII5teKreVQE/attkghWkT9tG3rXWEUQGk2cbXS0Vvn+KRE1JFpJce+0FtVzRa0bJVpS2MwKypTxXNf+OwitNdzlB6wBq2BU7qsET+VSYG4gx7XbSnrkjh2N1Jd0I5uNrC5Gb8y8cnpMdXQo1WUNUSua3V4gmT9wwmlZyCRXaYkXHSZnpYTAnTM7ZLB39+xXLgxEBb0b8Sof62WsBiMiy4xpuLTtQUnuolnNZtaq0KzMxSaiOrAO52S2hsPvR8jFLZKZMEhRPFZX+DNxijBE7zM/m0XE7nvnsqMo0Q7w2EvjOXHuoagOcZUfjlkewJEfRywBqH2k8LxR5fuLdVwWWoy+X6tfBpYf0Tdc5up972rxB9w+tDyndIRqYW2j2xQFpx6QUzcW8DbJf20WrCRqPiL6Ut+kh5x7iAa78wfcgzc7dXue1eUpgDHMA5dymqNKHhfjRaIu1F8sAE245qkYrXhh+jbtUOkHp0XZ+Gf1IDvigAk0Q/2isajwpDWz0eJEHA1Y1oJfj8a1q3yiGUOmpvnlcmjDAhkTKY8UiD0YWjIHa/sbYhIwCw=="
    static let rsa4096SHA512SignatureBlob = "AAAADHJzYS1zaGEyLTUxMgAAAgCdP0/Gi0JsRpmQ3TAYrO2wSf5up0yOe5JGu62wRltNy6eDi9J4r9h+m6mRe+F0vJjO8D0rB11+rds9XC3XQTUcCRXB7oE4gT7BOAmQhMKZzu58ggf7B1dHaYfWp1lBmotQzrugZuPHmwd+qaBQu2cn022wDPlf3KuLIFT3qJCevztZee373XNfq3CGtoIdfGN5s9rqQ1lZqkmcCRIBaV/RWkWOrA75Ot8MxpGhN69lgRmWj2IiFu+8V8apIZLUng/cwJYbuz3822D7gYYs9A2nXP//4aUYdSGp2zwzNvGy/r6tOd8RTgCnZzw9Mt84YBi0VgshKjB9NcuhHysHfzwqLpTh8ai2IGzM1ZnuLhYYJ+XmMp4F22xmsv/pWTMs8CRWRR4nQA84q2XQj+w9gHtTllJkehOTev9eNUCBrw/GGs7W3zU6H+JsQmKa1614oFcZZs5PSSSDtBgLmpaC5FH9Az6kF/CRlnRR5j52eIghNnN8jF9AgNQirqTbpKLL19pW0CtnpKqMnTwyeUZQ0S9cBVAfRG1b7Y6ltVPUJjob5zkYSAXx+TRu8BLQgy/CdjjO+4ECNgKBLNIic0s4GrZUQbqilumVc0ApvIiS6E3GOBagRGqcfza+l2XPciJWR+95w7bLE10dSFJQXgHKv38uN4jGxapTmUfpER5zoJGQPQ=="

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
