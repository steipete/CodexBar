import Foundation

enum TraeUsageParser {
    static func parse(json: String, now: Date = Date()) throws -> TraeUsageSnapshot {
        guard let data = json.data(using: .utf8) else {
            throw TraeUsageError.parseFailed("Invalid UTF-8 encoding")
        }

        guard let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = object as? [String: Any]
        else {
            throw TraeUsageError.parseFailed("Invalid JSON structure")
        }

        guard let entitlementList = dict["user_entitlement_pack_list"] as? [[String: Any]]
        else {
            if self.looksSignedOut(dict) {
                throw TraeUsageError.notLoggedIn
            }
            throw TraeUsageError.parseFailed("Missing user_entitlement_pack_list")
        }

        // Parse all entitlements with valid data (not just status == 1)
        var entitlements: [TraeEntitlementInfo] = []
        var allFeatures = TraeFeatures()

        for entitlement in entitlementList {
            guard let baseInfo = entitlement["entitlement_base_info"] as? [String: Any],
                  let quota = baseInfo["quota"] as? [String: Any],
                  let usage = entitlement["usage"] as? [String: Any]
            else { continue }

            // Get status (0 or 1) - include all for display like web UI does
            let status = entitlement["status"] as? Int ?? 0

            // Parse fast request quota
            var totalCredits: Double = 0
            var isUnlimited = false
            if let fastLimit = quota["premium_model_fast_request_limit"] as? Double {
                if fastLimit == -1 {
                    isUnlimited = true
                } else if fastLimit > 0 {
                    totalCredits = fastLimit
                }
            } else if let fastLimitInt = quota["premium_model_fast_request_limit"] as? Int {
                if fastLimitInt == -1 {
                    isUnlimited = true
                } else if fastLimitInt > 0 {
                    totalCredits = Double(fastLimitInt)
                }
            }

            // Skip entitlements with no quota at all
            if totalCredits == 0 && !isUnlimited {
                continue
            }

            // Parse used amount
            var usedCredits: Double = 0
            if let fastUsed = usage["premium_model_fast_amount"] as? Double {
                usedCredits = fastUsed
            } else if let fastUsedInt = usage["premium_model_fast_amount"] as? Int {
                usedCredits = Double(fastUsedInt)
            }

            // Determine reset/expire date
            // For Pro plan (product_type: 1), use next_billing_time if available
            // For packages (product_type: 2), use end_time
            let productType = baseInfo["product_type"] as? Int ?? 0
            var resetsAt: Date?
            
            if productType == 1 {
                // Pro plan uses next_billing_time for reset
                if let nextBilling = entitlement["next_billing_time"] as? Double, nextBilling > 0 {
                    resetsAt = Date(timeIntervalSince1970: nextBilling)
                } else if let endTime = baseInfo["end_time"] as? Double {
                    resetsAt = Date(timeIntervalSince1970: endTime)
                } else if let endTimeInt = baseInfo["end_time"] as? Int {
                    resetsAt = Date(timeIntervalSince1970: Double(endTimeInt))
                }
            } else {
                // Packages use end_time as expiry
                if let endTime = baseInfo["end_time"] as? Double {
                    resetsAt = Date(timeIntervalSince1970: endTime)
                } else if let endTimeInt = baseInfo["end_time"] as? Int {
                    resetsAt = Date(timeIntervalSince1970: Double(endTimeInt))
                }
            }

            // Determine name based on product_type and product_extra
            let name = extractEntitlementName(baseInfo: baseInfo, productType: productType)

            entitlements.append(TraeEntitlementInfo(
                name: name,
                totalCredits: totalCredits,
                usedCredits: usedCredits,
                expiresAt: resetsAt,
                productType: productType,
                isUnlimited: isUnlimited,
                isActive: status == 1))

            // Collect features only from active entitlements (status == 1)
            // to avoid showing features from expired/inactive plans
            if status == 1 {
                let hasSoloBuilder = quota["enable_solo_builder"] as? Bool ?? false
                let hasSoloCoder = quota["enable_solo_coder"] as? Bool ?? false
                
                var hasUnlimitedSlow = false
                if let slowLimit = quota["premium_model_slow_request_limit"] as? Double, slowLimit == -1 {
                    hasUnlimitedSlow = true
                } else if let slowLimit = quota["premium_model_slow_request_limit"] as? Int, slowLimit == -1 {
                    hasUnlimitedSlow = true
                }

                var hasUnlimitedAdvanced = false
                if let advancedLimit = quota["premium_model_advanced_request_limit"] as? Double, advancedLimit == -1 {
                    hasUnlimitedAdvanced = true
                } else if let advancedLimit = quota["premium_model_advanced_request_limit"] as? Int, advancedLimit == -1 {
                    hasUnlimitedAdvanced = true
                }

                var hasUnlimitedAutocomplete = false
                if let autoLimit = quota["auto_completion_limit"] as? Double, autoLimit == -1 {
                    hasUnlimitedAutocomplete = true
                } else if let autoLimit = quota["auto_completion_limit"] as? Int, autoLimit == -1 {
                    hasUnlimitedAutocomplete = true
                }

                // Merge features - if any active entitlement has it, keep it
                if hasSoloBuilder { allFeatures.hasSoloBuilder = true }
                if hasSoloCoder { allFeatures.hasSoloCoder = true }
                if hasUnlimitedSlow { allFeatures.hasUnlimitedSlow = true }
                if hasUnlimitedAdvanced { allFeatures.hasUnlimitedAdvanced = true }
                if hasUnlimitedAutocomplete { allFeatures.hasUnlimitedAutocomplete = true }
            }
        }

        guard !entitlements.isEmpty else {
            throw TraeUsageError.parseFailed("No entitlements found with valid quotas")
        }

        // Sort entitlements:
        // 1. Pro Plan first
        // 2. Active entitlements before inactive
        // 3. Then by expiry date (soonest first)
        let sortedEntitlements = entitlements.sorted { a, b in
            // Pro Plan always first
            if a.productType == 1 && b.productType != 1 { return true }
            if a.productType != 1 && b.productType == 1 { return false }
            
            // Active before inactive
            if a.isActive && !b.isActive { return true }
            if !a.isActive && b.isActive { return false }
            
            // Then by expiry date
            if let aDate = a.expiresAt, let bDate = b.expiresAt {
                return aDate < bDate
            }
            return a.expiresAt != nil
        }

        return TraeUsageSnapshot(
            entitlements: sortedEntitlements,
            features: allFeatures,
            totalEntitlements: entitlementList.count,
            activeEntitlements: sortedEntitlements.filter { $0.isActive }.count,
            updatedAt: now)
    }

    /// Extract a human-readable name for the entitlement
    private static func extractEntitlementName(baseInfo: [String: Any], productType: Int) -> String {
        // For Pro plan, always use "Pro Plan"
        if productType == 1 {
            return "Pro Plan"
        }
        
        // For packages, try to get descriptive name from product_extra
        if let productExtra = baseInfo["product_extra"] as? [String: Any],
           let packageExtra = productExtra["package_extra"] as? [String: Any] {
            
            // Get package source type for naming
            if let sourceType = packageExtra["package_source_type"] as? Int {
                switch sourceType {
                case 1:
                    return "Extra Package"
                case 2:
                    return "Extra Package (Official Bonus)"
                case 6:
                    return "Extra Package (Anniversary Treat)"
                default:
                    break
                }
            }
        }
        
        return "Extra Package"
    }

    private static func looksSignedOut(_ dict: [String: Any]) -> Bool {
        if let error = dict["error"] as? String {
            let lower = error.lowercased()
            return lower.contains("unauthorized") || lower.contains("not logged in") || lower.contains("auth")
        }
        if let message = dict["message"] as? String {
            let lower = message.lowercased()
            return lower.contains("login") || lower.contains("sign in") || lower.contains("auth")
        }
        return false
    }
}
