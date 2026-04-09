import SwiftUI

struct AcknowledgmentsView: View {
    var body: some View {
        List {
            Section {
                Text(argon2SwiftLicense)
                    .font(.caption)
                    .monospaced()
            } header: {
                Text("Argon2Swift")
            } footer: {
                Text("MIT License")
            }

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
                Text(swiftyDropboxLicense)
                    .font(.caption)
                    .monospaced()
            } header: {
                Text("SwiftyDropbox")
            } footer: {
                Text("MIT License")
            }
        }
        .navigationTitle("Acknowledgments")
        .navigationBarTitleDisplayMode(.inline)
    }

    private let argon2SwiftLicense = """
        Copyright 2020 Tejas Mehta <tmthecoder@gmail.com>

        Permission is hereby granted, free of charge, to any person obtaining \
        a copy of this software and associated documentation files (the \
        "Software"), to deal in the Software without restriction, including \
        without limitation the rights to use, copy, modify, merge, publish, \
        distribute, sublicense, and/or sell copies of the Software, and to \
        permit persons to whom the Software is furnished to do so, subject to \
        the following conditions:

        The above copyright notice and this permission notice shall be included \
        in all copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS \
        OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF \
        MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. \
        IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY \
        CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, \
        TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE \
        SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
        """

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
}
