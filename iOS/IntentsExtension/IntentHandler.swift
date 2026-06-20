import Intents

class IntentHandler: INExtension {
    override func handler(for intent: INIntent) -> Any {
        if intent is INAddTasksIntent {
            return AddTasksHandler()
        }
        return self
    }
}

// MARK: - INAddTasksIntentHandling

class AddTasksHandler: NSObject, INAddTasksIntentHandling {

    private let defaults = UserDefaults(suiteName: "group.com.patbarlow.shoppinglist")
    private let baseURL = "https://shopping-list-api.pat-barlow.workers.dev"

    func resolveTargetTaskList(for intent: INAddTasksIntent,
                               with completion: @escaping (INAddTasksTargetTaskListResolutionResult) -> Void) {
        completion(.notRequired())
    }

    func resolveTaskTitles(for intent: INAddTasksIntent,
                           with completion: @escaping ([INSpeakableStringResolutionResult]) -> Void) {
        guard let titles = intent.taskTitles, !titles.isEmpty else {
            completion([.notRequired()])
            return
        }
        completion(titles.map { .success(with: $0) })
    }

    func handle(intent: INAddTasksIntent, completion: @escaping (INAddTasksIntentResponse) -> Void) {
        guard let token = defaults?.string(forKey: "sl_token"),
              let householdId = defaults?.string(forKey: "sl_household_id") else {
            completion(INAddTasksIntentResponse(code: .failureRequiringAppLaunch, userActivity: nil))
            return
        }

        let names = (intent.taskTitles ?? []).map { $0.spokenPhrase }
        guard !names.isEmpty else {
            completion(INAddTasksIntentResponse(code: .failure, userActivity: nil))
            return
        }

        Task {
            var addedTasks: [INTask] = []
            for name in names {
                guard let url = URL(string: "\(baseURL)/v1/items") else { continue }
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.timeoutInterval = 8
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                req.httpBody = try? JSONSerialization.data(withJSONObject: [
                    "household_id": householdId,
                    "name": name
                ])
                guard let (_, resp) = try? await URLSession.shared.data(for: req),
                      let http = resp as? HTTPURLResponse,
                      (200...299).contains(http.statusCode)
                else { continue }

                addedTasks.append(INTask(
                    title: INSpeakableString(spokenPhrase: name),
                    status: .notCompleted,
                    taskType: .notCompletable,
                    spatialEventTrigger: nil,
                    temporalEventTrigger: nil,
                    createdDateComponents: nil,
                    modifiedDateComponents: nil,
                    identifier: nil
                ))
            }

            let response = INAddTasksIntentResponse(code: .success, userActivity: nil)
            response.addedTasks = addedTasks
            completion(response)
        }
    }
}
