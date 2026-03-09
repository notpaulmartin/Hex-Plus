import ComposableArchitecture
import Inject
import SwiftUI

struct LLMSettingsView: View {
  @ObserveInjection var inject
  @Bindable var store: StoreOf<SettingsFeature>

  var body: some View {
    Form {
      Section("LLM Post-processing") {
        Toggle("Enable LLM Post-processing", isOn: $store.hexSettings.llmPostProcessingEnabled)
        Text("When enabled, transcription output is sent to the configured LLM before insertion.")
          .settingsCaption()
      }

      Section("Prompt") {
        TextField(
          "Prompt to prepend before the transcript",
          text: $store.hexSettings.llmPromptPrefix,
          axis: .vertical
        )
        .lineLimit(3...8)

        Text("This prompt is prepended to the transcribed text for each LLM request.")
          .settingsCaption()
      }

      Section("AI Provider Settings") {
        Picker("Provider", selection: $store.hexSettings.llmProvider) {
          Text("OpenAI Compatible").tag(LLMProvider.openAICompatible)
        }
        .pickerStyle(.menu)

        SecureField("API Key", text: $store.hexSettings.llmAPIKey)
        TextField("Model", text: $store.hexSettings.llmModel)
        TextField("Endpoint URL", text: $store.hexSettings.llmBaseURL)
      }
    }
    .formStyle(.grouped)
    .enableInjection()
  }
}
