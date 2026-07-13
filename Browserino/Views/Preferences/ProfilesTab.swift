//
//  ProfilesTab.swift
//  Browserino
//

import SwiftUI

struct ProfilesTab: View {
    @AppStorage("chromeProfiles") private var chromeProfiles: [ChromeProfile] = []
    @AppStorage("chromeProfilesEnabled") private var chromeProfilesEnabled: Bool = true

    @State private var hasDetected = false

    private var chromeInstalled: Bool {
        ChromeProfileUtil.chromeURL() != nil
    }

    private func detectProfiles() {
        let detected = ChromeProfileUtil.detectProfiles()

        // Keep existing profiles in their user-arranged order, then append new ones.
        var merged: [ChromeProfile] = chromeProfiles.filter { existing in
            detected.contains { $0.directoryName == existing.directoryName }
        }
        for profile in detected where !merged.contains(where: { $0.directoryName == profile.directoryName }) {
            merged.append(profile)
        }

        chromeProfiles = merged
        hasDetected = true
    }

    private func displayName(at index: Int) -> Binding<String> {
        Binding(
            get: { chromeProfiles[index].displayName },
            set: { chromeProfiles[index].displayName = $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading) {
            if !chromeInstalled {
                Spacer()
                Text("Google Chrome is not installed.")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                HStack(spacing: 16) {
                    Toggle(isOn: $chromeProfilesEnabled) {
                        Text("Show Chrome profiles as separate items in the picker")
                            .font(.callout)
                    }

                    Spacer()

                    Button(action: detectProfiles) {
                        Text("Detect Profiles")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                List {
                    ForEach(Array(chromeProfiles.enumerated()), id: \.element.directoryName) { index, profile in
                        HStack {
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(.secondary)

                            Spacer()
                                .frame(width: 8)

                            TextField("Display name", text: displayName(at: index))
                                .font(.system(size: 14))
                                .frame(maxWidth: 200)

                            Spacer()
                                .frame(width: 16)

                            Text(profile.directoryName)
                                .font(.system(size: 12).monospaced())
                                .foregroundStyle(.secondary)

                            Spacer()

                            ShortcutButton(
                                browserId: "\(ChromeProfileUtil.chromeBundleID)::\(profile.directoryName)"
                            )

                            Spacer()
                                .frame(width: 8)

                            Button(action: {
                                chromeProfiles[index].isHidden.toggle()
                            }) {
                                Image(
                                    systemName: profile.isHidden
                                        ? "eye.slash.fill" : "eye.fill"
                                )
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(10)
                    }
                    .onMove { indices, newOffset in
                        chromeProfiles.move(fromOffsets: indices, toOffset: newOffset)
                    }
                }

                Text("Detect Chrome profiles and show them as separate picker items. Assign shortcuts, hide profiles you don't use, and drag to reorder them in the picker.")
                    .font(.subheadline)
                    .foregroundStyle(.primary.opacity(0.5))
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.bottom, 20)
        .onAppear {
            if !hasDetected && chromeInstalled && chromeProfiles.isEmpty {
                detectProfiles()
            }
        }
    }
}

#Preview {
    ProfilesTab()
}
