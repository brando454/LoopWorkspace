import SwiftUI

// Shown after pairing code is entered, while Loop initiates the BLE connection.
struct TandemConnectingView: View {
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            ProgressView()
                .scaleEffect(1.5)

            VStack(spacing: 8) {
                Text("Connecting…")
                    .font(.title2).bold()
                Text("Keep your Tandem Mobi close.\nLoop will scan for your pump in the background.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Spacer()

            Button {
                onDone()
            } label: {
                Text("Done")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                    .font(.headline)
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .navigationTitle("Tandem Mobi")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
    }
}
