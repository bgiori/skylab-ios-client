//
//  SkylabClient.swift
//  Skylab
//
//  Copyright © 2020 Amplitude. All rights reserved.
//

import Foundation

public protocol SkylabClient {
    func start(user: SkylabUser, completion: (() -> Void)?) -> Void
    func setUser(user: SkylabUser, completion: (() -> Void)?) -> Void
    func getVariant(_ flagKey: String, fallback: Variant?) -> Variant?
    func getVariant(_ flagKey: String, fallback: String) -> Variant
    func getVariants() -> [String:Variant]
    func refetchAll(completion: (() -> Void)?) -> Void
    func setContextProvider(_ contextProvider: ContextProvider) -> SkylabClient
}

public extension SkylabClient {
    func getVariant(_ flagKey: String, fallback: Variant? = nil) -> Variant? {
        return getVariant(flagKey, fallback: fallback)
    }

    func getVariant(_ flagKey: String, fallback: String) -> Variant {
        return getVariant(flagKey, fallback: fallback)
    }
}

let EnrollmentIdKey: String = "com.amplitude.flags.enrollmentId"

public class DefaultSkylabClient : SkylabClient {

    internal let apiKey: String
    internal let storage: Storage
    internal let config: SkylabConfig
    internal var userId: String?
    internal var user: SkylabUser?
    internal var contextProvider: ContextProvider?
    internal var enrollmentId: String?

    init(apiKey: String, config: SkylabConfig) {
        self.apiKey = apiKey
        self.storage = UserDefaultsStorage(apiKey: apiKey)
        self.config = config
        self.userId = nil
        self.user = nil
        self.contextProvider = nil
    }


    public func start(user: SkylabUser, completion: (() -> Void)? = nil) -> Void {
        self.user = user
        self.loadFromStorage()
        self.fetchAll(completion: completion)
    }

    public func setUser(user: SkylabUser, completion: (() -> Void)? = nil) -> Void {
        self.user = user
        self.fetchAll(completion: completion)
    }

    public func refetchAll(completion: (() -> Void)? = nil) -> Void {
        self.fetchAll(completion:completion)
    }

    private func addContext(user:SkylabUser?) -> [String:Any] {
        var userContext:[String:Any] = [:]
        if (self.contextProvider != nil) {
            userContext["device_id"] = self.contextProvider?.getDeviceId()
            userContext["user_id"] = self.contextProvider?.getUserId()
            userContext["version"] = self.contextProvider?.getVersion()
            userContext["language"] = self.contextProvider?.getLanguage()
            userContext["platform"] = self.contextProvider?.getPlatform()
            userContext["os"] = self.contextProvider?.getOs()
            userContext["device_manufacturer"] = self.contextProvider?.getDeviceManufacturer()
            userContext["device_model"] = self.contextProvider?.getDeviceModel()
        }
        userContext["library"] = "\(SkylabConfig.Constants.Library)/\(SkylabConfig.Constants.Version)"
        userContext.merge(user?.toDictionary() ?? [:]) { (_, new) in new }
        return userContext
    }

    public func fetchAll(completion:  (() -> Void)? = nil) {
        let start = CFAbsoluteTimeGetCurrent()
        DispatchQueue.global(qos: .background).async {
            let session = URLSession.shared

            let userContext = self.addContext(user:self.user)
            
            let userId = userContext["user_id"]
            let deviceId = userContext["device_id"]
            if userId == nil && deviceId == nil {
                print("[Skylab] WARN: user id and device id are null; amplitude will not be able to resolve identity")
            }
            
            do {
                let requestData = try JSONSerialization.data(withJSONObject: userContext, options: [])
                let b64encodedUrl = requestData.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "=", with: "")

                let url = URL(string: "\(self.config.serverUrl)/sdk/vardata/\(b64encodedUrl)")!
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.setValue("Api-Key \(self.apiKey)", forHTTPHeaderField: "Authorization")
                let task = session.dataTask(with: request) { (data, response, error) in
                    // Check the response
                    if let httpResponse = response as? HTTPURLResponse {

                        // Check if an error occured
                        if (error != nil) {
                            // HERE you can manage the error
                            print("[Skylab] \(error!)")
                            completion?()
                            return
                        }

                        if (httpResponse.statusCode != 200) {
                            print("[Skylab] \(httpResponse.statusCode) received for \(url)")
                            completion?()
                            return
                        }

                        // Serialize the data into an object
                        do {
                            let flags = try JSONSerialization.jsonObject(with: data!, options: []) as? [String: [String: Any]] ?? [:]
                            self.storage.clear()
                            for (key, value) in flags {
                                let variant = Variant(json: value)
                                if (variant != nil) {
                                    let _ = self.storage.put(key: key, value: variant!)
                                }
                            }
                            self.storage.save()
                            let end = CFAbsoluteTimeGetCurrent()
                            print("[Skylab] Fetched all: \(flags) for user \(userContext) in \(end - start)s")
                        } catch {
                            print("[Skylab] Error during JSON serialization: \(error.localizedDescription)")
                        }
                    }

                    completion?()
                }
                task.resume()
            } catch {
                print("[Skylab] Error during JSON serialization: \(error.localizedDescription)")
            }
        }
    }

    public func getVariant(_ flagKey: String, fallback: String) -> Variant {
        return self.storage.get(key: flagKey) ?? Variant(fallback, payload:nil)
    }

    public func getVariant(_ flagKey: String, fallback: Variant?) -> Variant? {
        return self.storage.get(key: flagKey) ?? fallback ?? self.config.initialFlags[flagKey] ?? self.config.fallbackVariant
    }

    public func getVariants() -> [String: Variant] {
        return self.storage.getAll()
    }

    public func setContextProvider(_ contextProvider: ContextProvider) -> SkylabClient {
        self.contextProvider = contextProvider
        return self
    }

    func loadFromStorage() -> Void {
        self.loadEnrollmentId()
        self.storage.load()
        print("[Skylab] loaded \(self.storage.getAll())")
    }

    func loadEnrollmentId() -> Void {
        enrollmentId = UserDefaults.standard.string(forKey: EnrollmentIdKey)
        if (enrollmentId == nil) {
            enrollmentId = generateEnrollmentId()
            print("generated \(enrollmentId!)")
            UserDefaults.standard.set(enrollmentId, forKey: EnrollmentIdKey)
        }
    }
}

func generateEnrollmentId() -> String {
    let letters = "abcdefghijklmnopqrstuvwxyz0123456789"
    return String((0..<25).map{ _ in letters.randomElement()! })
}
