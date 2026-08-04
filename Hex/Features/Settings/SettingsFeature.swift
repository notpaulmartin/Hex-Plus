import AVFoundation
import AppKit
import ComposableArchitecture
import Dependencies
import HexCore
import IdentifiedCollections
import Sauce
import ServiceManagement
import SwiftUI

private let settingsLogger = HexLog.settings

extension SharedReaderKey
  where Self == InMemoryKey<Bool>.Default
{
  static var isSettingHotKey: Self {
    Self[.inMemory("isSettingHotKey"), default: false]
  }
  
  static var isSettingPasteLastTranscriptHotkey: Self {
    Self[.inMemory("isSettingPasteLastTranscriptHotkey"), default: false]
  }

  static var isRemappingScratchpadFocused: Self {
    Self[.inMemory("isRemappingScratchpadFocused"), default: false]
  }
}

// MARK: - Settings Feature

@Reducer
struct SettingsFeature {
  private enum CancelID {
    case groqAPIKeySave
  }

  @ObservableState
  struct State {
    @Shared(.hexSettings) var hexSettings: HexSettings
    @Shared(.isSettingHotKey) var isSettingHotKey: Bool = false
    @Shared(.isSettingPasteLastTranscriptHotkey) var isSettingPasteLastTranscriptHotkey: Bool = false
    @Shared(.isRemappingScratchpadFocused) var isRemappingScratchpadFocused: Bool = false
    @Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory
    @Shared(.hotkeyPermissionState) var hotkeyPermissionState: HotkeyPermissionState

    var languages: IdentifiedArrayOf<Language> = []
    var currentModifiers: Modifiers = .init(modifiers: [])
    var currentPasteLastModifiers: Modifiers = .init(modifiers: [])
    var remappingScratchpadText: String = ""
    
    // Available microphones
    var availableInputDevices: [AudioInputDevice] = []
    var defaultInputDeviceName: String?

    // Model Management
    var modelDownload = ModelDownloadFeature.State()
    var shouldFlashModelSection = false
    var groqAPIKey = ""
    var groqAPIKeyError: String?

  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)

    // Existing
    case task
    case startSettingHotKey
    case startSettingPasteLastTranscriptHotkey
    case clearPasteLastTranscriptHotkey
    case keyEvent(KeyEvent)
    case toggleOpenOnLogin(Bool)
    case togglePreventSystemSleep(Bool)
    case setRecordingAudioBehavior(RecordingAudioBehavior)

    // Permission delegation (forwarded to AppFeature)
    case requestMicrophone
    case requestAccessibility
    case requestInputMonitoring

    // Microphone selection
    case loadAvailableInputDevices
    case availableInputDevicesLoaded([AudioInputDevice], String?)

    // Model Management
    case modelDownload(ModelDownloadFeature.Action)
    case selectTranscriptionBackend(TranscriptionBackend)
    case groqAPIKeyLoaded(Result<String, Error>)
    case groqAPIKeyChanged(String)
    case groqAPIKeySaved(Result<Void, Error>)
    
    // History Management
    case toggleSaveTranscriptionHistory(Bool)

    // Modifier configuration
    case setModifierSide(Modifier.Kind, Modifier.Side)

    // Word remappings
    case addWordRemoval
    case removeWordRemoval(UUID)
    case addWordRemapping
    case removeWordRemapping(UUID)
    case setRemappingScratchpadFocused(Bool)
  }

  @Dependency(\.keyEventMonitor) var keyEventMonitor
  @Dependency(\.continuousClock) var clock
  @Dependency(\.transcription) var transcription
  @Dependency(\.recording) var recording
  @Dependency(\.permissions) var permissions
  @Dependency(\.groqAPIKey) var groqAPIKey

  var body: some ReducerOf<Self> {
    BindingReducer()

    Scope(state: \.modelDownload, action: \.modelDownload) {
      ModelDownloadFeature()
    }

    Reduce { state, action in
      switch action {
      case .binding:
        if !state.hexSettings.doubleTapLockEnabled, state.hexSettings.useDoubleTapOnly {
          state.$hexSettings.withLock {
            $0.useDoubleTapOnly = false
          }
        }

        return .run { _ in
          await MainActor.run {
            NotificationCenter.default.post(name: .updateAppMode, object: nil)
          }
        }

      case .task:
        if let url = Bundle.main.url(forResource: "languages", withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let languages = try? JSONDecoder().decode([Language].self, from: data)
        {
          state.languages = IdentifiedArray(uniqueElements: languages)
        } else {
          settingsLogger.error("Failed to load languages JSON from bundle")
        }

        // Listen for key events and load microphones (existing + new)
        return .run { send in
          await send(.groqAPIKeyLoaded(Result { try groqAPIKey.load() }))
          await send(.modelDownload(.fetchModels))
          await send(.loadAvailableInputDevices)
          
          // Set up periodic refresh of available devices (every 120 seconds)
          // Using a longer interval to reduce resource usage
          let deviceRefreshTask = Task { @MainActor in
            for await _ in clock.timer(interval: .seconds(120)) {
              // Only refresh when the app is active to save resources
              if NSApplication.shared.isActive {
                send(.loadAvailableInputDevices)
              }
            }
          }
          
          // Listen for device connection/disconnection notifications
          // Using a simpler debounced approach with a single task
          var deviceUpdateTask: Task<Void, Never>?
          
          // Helper function to debounce device updates
          func debounceDeviceUpdate() {
            deviceUpdateTask?.cancel()
            deviceUpdateTask = Task {
              try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
              if !Task.isCancelled {
                await send(.loadAvailableInputDevices)
              }
            }
          }
          
          let deviceConnectionObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name(rawValue: "AVCaptureDeviceWasConnected"),
            object: nil,
            queue: .main
          ) { _ in
            debounceDeviceUpdate()
          }
          
          let deviceDisconnectionObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name(rawValue: "AVCaptureDeviceWasDisconnected"),
            object: nil,
            queue: .main
          ) { _ in
            debounceDeviceUpdate()
          }
          
          // Be sure to clean up resources when the task is finished
          defer {
            deviceUpdateTask?.cancel()
            NotificationCenter.default.removeObserver(deviceConnectionObserver)
            NotificationCenter.default.removeObserver(deviceDisconnectionObserver)
          }

          for try await keyEvent in await keyEventMonitor.listenForKeyPress() {
            await send(.keyEvent(keyEvent))
          }
          
          deviceRefreshTask.cancel()
        }

      case let .selectTranscriptionBackend(backend):
        state.$hexSettings.withLock { $0.transcriptionBackend = backend }
        state.modelDownload.$modelBootstrapState.withLock { bootstrap in
          switch backend {
          case .local:
            bootstrap.modelIdentifier = state.hexSettings.selectedModel
            bootstrap.modelDisplayName = state.hexSettings.selectedModel
            bootstrap.isModelReady = state.modelDownload.selectedModelIsDownloaded
            bootstrap.lastError = nil
            bootstrap.progress = bootstrap.isModelReady ? 1 : 0
          case .groq:
            bootstrap.modelIdentifier = state.hexSettings.groqTranscriptionModel.rawValue
            bootstrap.modelDisplayName = "Groq · \(state.hexSettings.groqTranscriptionModel.displayName)"
            bootstrap.isModelReady = !state.groqAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            bootstrap.lastError = nil
            bootstrap.progress = bootstrap.isModelReady ? 1 : 0
          }
        }
        return .none

      case let .groqAPIKeyLoaded(.success(apiKey)):
        state.groqAPIKey = apiKey
        state.groqAPIKeyError = nil
        if state.hexSettings.transcriptionBackend == .groq {
          state.modelDownload.$modelBootstrapState.withLock {
            $0.isModelReady = !apiKey.isEmpty
            $0.progress = apiKey.isEmpty ? 0 : 1
          }
        }
        return .none

      case let .groqAPIKeyLoaded(.failure(error)):
        state.groqAPIKeyError = error.localizedDescription
        return .none

      case let .groqAPIKeyChanged(apiKey):
        state.groqAPIKey = apiKey
        state.groqAPIKeyError = nil
        if state.hexSettings.transcriptionBackend == .groq {
          state.modelDownload.$modelBootstrapState.withLock {
            $0.isModelReady = !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            $0.progress = $0.isModelReady ? 1 : 0
          }
        }
        return .run { send in
          try? await clock.sleep(for: .milliseconds(300))
          guard !Task.isCancelled else { return }
          await send(.groqAPIKeySaved(Result { try groqAPIKey.save(apiKey) }))
        }
        .cancellable(id: CancelID.groqAPIKeySave, cancelInFlight: true)

      case .groqAPIKeySaved(.success):
        state.groqAPIKeyError = nil
        return .none

      case let .groqAPIKeySaved(.failure(error)):
        state.groqAPIKeyError = error.localizedDescription
        return .none

      case .startSettingHotKey:
        state.$isSettingHotKey.withLock { $0 = true }
        return .none

      case .addWordRemoval:
        state.$hexSettings.withLock {
          $0.wordRemovals.append(.init(pattern: ""))
        }
        return .none

      case let .removeWordRemoval(id):
        state.$hexSettings.withLock {
          $0.wordRemovals.removeAll { $0.id == id }
        }
        return .none

      case .addWordRemapping:
        state.$hexSettings.withLock {
          $0.wordRemappings.append(.init(match: "", replacement: ""))
        }
        return .none

      case let .removeWordRemapping(id):
        state.$hexSettings.withLock {
          $0.wordRemappings.removeAll { $0.id == id }
        }
        return .none

      case let .setRemappingScratchpadFocused(isFocused):
        state.$isRemappingScratchpadFocused.withLock { $0 = isFocused }
        return .none

      case .startSettingPasteLastTranscriptHotkey:
        state.$isSettingPasteLastTranscriptHotkey.withLock { $0 = true }
        state.currentPasteLastModifiers = .init(modifiers: [])
        return .none
        
      case .clearPasteLastTranscriptHotkey:
        state.$hexSettings.withLock { $0.pasteLastTranscriptHotkey = nil }
        return .none

      case let .keyEvent(keyEvent):
        // Handle paste last transcript hotkey setting
        if state.isSettingPasteLastTranscriptHotkey {
          if keyEvent.key == .escape {
            state.$isSettingPasteLastTranscriptHotkey.withLock { $0 = false }
            state.currentPasteLastModifiers = []
            return .none
          }

          state.currentPasteLastModifiers = keyEvent.modifiers.union(state.currentPasteLastModifiers)
          let currentModifiers = state.currentPasteLastModifiers
          if let key = keyEvent.key {
            guard !currentModifiers.isEmpty else {
              return .none
            }
            state.$hexSettings.withLock {
              $0.pasteLastTranscriptHotkey = HotKey(key: key, modifiers: currentModifiers.erasingSides())
            }
            state.$isSettingPasteLastTranscriptHotkey.withLock { $0 = false }
            state.currentPasteLastModifiers = []
          }
          return .none
        }
        
        // Handle main recording hotkey setting
        guard state.isSettingHotKey else { return .none }

        if keyEvent.key == .escape {
          state.$isSettingHotKey.withLock { $0 = false }
          state.currentModifiers = []
          return .none
        }

        state.currentModifiers = keyEvent.modifiers.union(state.currentModifiers)
        let currentModifiers = state.currentModifiers
        if let key = keyEvent.key {
          state.$hexSettings.withLock {
            $0.hotkey.key = key
            $0.hotkey.modifiers = currentModifiers.erasingSides()
          }
          state.$isSettingHotKey.withLock { $0 = false }
          state.currentModifiers = []
        } else if keyEvent.modifiers.isEmpty {
          state.$hexSettings.withLock {
            $0.hotkey.key = nil
            $0.hotkey.modifiers = currentModifiers.erasingSides()
          }
          state.$isSettingHotKey.withLock { $0 = false }
          state.currentModifiers = []
        }
        return .none

      case let .toggleOpenOnLogin(enabled):
        state.$hexSettings.withLock { $0.openOnLogin = enabled }
        return .run { _ in
          if enabled {
            try? SMAppService.mainApp.register()
          } else {
            try? SMAppService.mainApp.unregister()
          }
        }

      case let .togglePreventSystemSleep(enabled):
        state.$hexSettings.withLock { $0.preventSystemSleep = enabled }
        return .none

      case let .setRecordingAudioBehavior(behavior):
        state.$hexSettings.withLock { $0.recordingAudioBehavior = behavior }
        return .none

      // Permission requests
      case .requestMicrophone:
        settingsLogger.info("User requested microphone permission from settings")
        return .run { _ in
          _ = await permissions.requestMicrophone()
        }

      case .requestAccessibility:
        settingsLogger.info("User requested accessibility permission from settings")
        return .run { _ in
          await permissions.requestAccessibility()
        }

      case .requestInputMonitoring:
        settingsLogger.info("User requested input monitoring permission from settings")
        return .run { _ in
          _ = await permissions.requestInputMonitoring()
        }

      // Model Management
      case let .modelDownload(.selectModel(newModel)):
        // Also store it in hexSettings:
        state.$hexSettings.withLock {
          $0.selectedModel = newModel
        }
        // Then continue with the child's normal logic:
        return .none

      case .modelDownload:
        return .none
      
      // Microphone device selection
      case .loadAvailableInputDevices:
        return .run { send in
          let devices = await recording.getAvailableInputDevices()
          let defaultName = await recording.getDefaultInputDeviceName()
          await send(.availableInputDevicesLoaded(devices, defaultName))
        }
        
      case let .availableInputDevicesLoaded(devices, defaultName):
        state.availableInputDevices = devices
        state.defaultInputDeviceName = defaultName
        return .none
        
      case let .toggleSaveTranscriptionHistory(enabled):
        state.$hexSettings.withLock { $0.saveTranscriptionHistory = enabled }
        
        // If disabling history, delete all existing entries
        if !enabled {
          let transcripts = state.transcriptionHistory.history
          
          // Clear the history
          state.$transcriptionHistory.withLock { history in
            history.history.removeAll()
          }
          
          // Delete all audio files
          return .run { _ in
            for transcript in transcripts {
              try? FileManager.default.removeItem(at: transcript.audioPath)
            }
          }
        }
        
        return .none

      case let .setModifierSide(kind, side):
        guard state.hexSettings.hotkey.key == nil else { return .none }
        state.$hexSettings.withLock {
          $0.hotkey.modifiers = $0.hotkey.modifiers.setting(kind: kind, to: side)
        }
        return .none

      }
    }
  }
}
