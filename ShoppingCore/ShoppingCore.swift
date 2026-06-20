import Foundation

public struct ShoppingCore {
    public static let appGroupIdentifier = "group.com.patbarlow.shoppinglist"
    public static let keychainAccessGroup = "T544U3WVL6.com.patbarlow.shoppinglist"
    
    /// Migrates existing data from UserDefaults.standard to the shared App Group suite.
    public static func migrateIfNeeded() {
        let shared = UserDefaults.sharedGroup
        let standard = UserDefaults.standard
        
        // Use a sentinel key to ensure migration only runs once
        let migrationKey = "sl_migration_complete_v1"
        guard !shared.bool(forKey: migrationKey) else { return }
        
        let keysToMigrate = [
            "sl_token",
            "sl_user",
            "sl_user_id",
            "sl_household_id",
            "sl_household",
            "sl_base_url",
            "item_name_history"
        ]
        
        for key in keysToMigrate {
            if let value = standard.object(forKey: key) {
                shared.set(value, forKey: key)
                // We keep the old data in standard for now as a safety measure,
                // but you could standard.removeObject(forKey: key) here if desired.
            }
        }
        
        shared.set(true, forKey: migrationKey)
        shared.synchronize()
    }
}

extension UserDefaults {
    public static var sharedGroup: UserDefaults {
        UserDefaults(suiteName: ShoppingCore.appGroupIdentifier) ?? .standard
    }
}
