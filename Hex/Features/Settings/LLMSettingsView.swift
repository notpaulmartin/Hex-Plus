import ComposableArchitecture
import Inject
import SwiftUI

struct LLMSettingsView: View {
  @ObserveInjection var inject
  @Bindable var store: StoreOf<SettingsFeature>

  var body: some View {
    Form {
      Section {
        Label {
          Toggle("Enable LLM Post-processing", isOn: $store.hexSettings.llmPostProcessingEnabled)
          Text("After transcription, send the result to an AI model to fix grammar, remove fillers, and reformat output.")
            .settingsCaption()
        } icon: {
          Image(systemName: "sparkles")
        }
      }

      Section {
        SecureField("API Key", text: $store.hexSettings.llmAPIKey)
        TextField("Model", text: $store.hexSettings.llmModel)
        TextField("Base URL", text: $store.hexSettings.llmBaseURL)
        Text("Compatible with OpenAI, Groq, Ollama, and any OpenAI-compatible endpoint.")
          .settingsCaption()
      } header: {
        Text("Provider")
      }

      Section {
        TextEditor(text: $store.hexSettings.llmPromptPrefix)
          .font(.body)
          .frame(minHeight: 120)
          .scrollContentBackground(.hidden)
          .padding(6)
          .background(Color(nsColor: .textBackgroundColor))
          .clipShape(RoundedRectangle(cornerRadius: 6))
          .overlay(
            RoundedRectangle(cornerRadius: 6)
              .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
          )
        Text("Prepended to each request. Leave empty to send the transcript without instructions.")
          .settingsCaption()
      } header: {
        Text("Prompt")
      }
    }
    .formStyle(.grouped)
    .enableInjection()
  }
}
