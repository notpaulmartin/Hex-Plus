import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct ModelSectionView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>
	let shouldFlash: Bool

	var body: some View {
		Section("Transcription Model") {
			Picker("Run transcription", selection: Binding(
				get: { store.hexSettings.transcriptionBackend },
				set: { store.send(.selectTranscriptionBackend($0)) }
			)) {
				Text("On this Mac").tag(TranscriptionBackend.local)
				Text("Groq Cloud").tag(TranscriptionBackend.groq)
			}
			.pickerStyle(.segmented)

			if store.hexSettings.transcriptionBackend == .local {
				ModelDownloadView(
					store: store.scope(state: \.modelDownload, action: \.modelDownload),
					shouldFlash: shouldFlash
				)
			} else {
				Picker("Model", selection: $store.hexSettings.groqTranscriptionModel) {
					ForEach(GroqTranscriptionModel.allCases, id: \.self) { model in
						Text(model.displayName).tag(model)
					}
				}
				SecureField("Groq API Key", text: Binding(
					get: { store.groqAPIKey },
					set: { store.send(.groqAPIKeyChanged($0)) }
				))
				Text("Your key is stored in macOS Keychain. Recordings are sent to Groq only while Groq Cloud is selected.")
					.settingsCaption()
				if let error = store.groqAPIKeyError {
					Text(error)
						.font(.caption)
						.foregroundStyle(.red)
				}
			}
		}
		.enableInjection()
	}
}
