import SwiftUI

struct AcknowledgmentsView: View {
    var body: some View {
        List {
            Section {
                Text(argon2License)
                    .font(.caption)
                    .monospaced()
            } header: {
                Text("Argon2 Reference Implementation")
            } footer: {
                Text("CC0 1.0 Universal / Apache 2.0 (dual-licensed)")
            }

            Section {
                Text(twofishLicense)
                    .font(.caption)
                    .monospaced()
            } header: {
                Text("Niels Ferguson Twofish Implementation")
            } footer: {
                Text("Permissive license with attribution")
            }

            Section {
                Text(swiftyDropboxLicense)
                    .font(.caption)
                    .monospaced()
            } header: {
                Text("SwiftyDropbox")
            } footer: {
                Text("MIT License")
            }

            Section {
                Text(msalLicense)
                    .font(.caption)
                    .monospaced()
            } header: {
                Text("Microsoft Authentication Library (MSAL)")
            } footer: {
                Text("MIT License")
            }

            Section {
                Text(swiftPSLLicense)
                    .font(.caption)
                    .monospaced()
            } header: {
                Text("swift-psl")
            } footer: {
                Text("MIT License")
            }

            Section {
                Text(publicSuffixListNotice)
                    .font(.caption)
                    .monospaced()
            } header: {
                Text("Public Suffix List")
            } footer: {
                Text("Mozilla Public License 2.0")
            }
        }
        .navigationTitle("Acknowledgments")
        .navigationBarTitleDisplayMode(.inline)
    }

    private let argon2License = """
        Argon2 reference source code package - reference C implementations

        Copyright 2015
        Daniel Dinu, Dmitry Khovratovich, Jean-Philippe Aumasson, \
        and Samuel Neves

        You may use this work under the terms of a Creative Commons CC0 1.0 \
        License/Waiver or the Apache Public License 2.0, at your option. The \
        terms of these licenses can be found at:

        - CC0 1.0 Universal : https://creativecommons.org/publicdomain/zero/1.0
        - Apache 2.0        : https://www.apache.org/licenses/LICENSE-2.0
        """

    private let twofishLicense = """
        Fast, portable, and easy-to-use Twofish implementation, Version 0.3.
        Copyright (c) 2002 by Niels Ferguson.

        The author hereby grants a perpetual license to everybody to use this \
        code for any purpose as long as the copyright message is included in \
        the source code of this or any derived work.

        This software is provided as-is, without any kind of warranty or \
        guarantee.
        """

    private let swiftyDropboxLicense = """
        Copyright (c) 2015-2021 Dropbox Inc., http://www.dropbox.com/

        Permission is hereby granted, free of charge, to any person obtaining \
        a copy of this software and associated documentation files (the \
        "Software"), to deal in the Software without restriction, including \
        without limitation the rights to use, copy, modify, merge, publish, \
        distribute, sublicense, and/or sell copies of the Software, and to \
        permit persons to whom the Software is furnished to do so, subject to \
        the following conditions:

        The above copyright notice and this permission notice shall be \
        included in all copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, \
        EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF \
        MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND \
        NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE \
        LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION \
        OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION \
        WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
        """

    private let msalLicense = """
        Copyright (c) Microsoft Corporation

        Permission is hereby granted, free of charge, to any person obtaining \
        a copy of this software and associated documentation files (the \
        "Software"), to deal in the Software without restriction, including \
        without limitation the rights to use, copy, modify, merge, publish, \
        distribute, sublicense, and/or sell copies of the Software, and to \
        permit persons to whom the Software is furnished to do so, subject to \
        the following conditions:

        The above copyright notice and this permission notice shall be \
        included in all copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, \
        EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF \
        MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND \
        NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE \
        LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION \
        OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION \
        WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
        """

    private let swiftPSLLicense = """
        Copyright 2025 Andrey Meshkov

        Permission is hereby granted, free of charge, to any person obtaining \
        a copy of this software and associated documentation files (the \
        "Software"), to deal in the Software without restriction, including \
        without limitation the rights to use, copy, modify, merge, publish, \
        distribute, sublicense, and/or sell copies of the Software, and to \
        permit persons to whom the Software is furnished to do so, subject to \
        the following conditions:

        The above copyright notice and this permission notice shall be \
        included in all copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, \
        EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF \
        MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND \
        NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE \
        LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION \
        OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION \
        WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
        """

    private let publicSuffixListNotice = """
        This Source Code Form is subject to the terms of the Mozilla Public \
        License, v. 2.0. If a copy of the MPL was not distributed with this \
        file, You can obtain one at https://mozilla.org/MPL/2.0/.

        The source data used to generate the bundled Public Suffix List is \
        available at https://github.com/publicsuffix/list.
        """
}
