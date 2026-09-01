import Foundation

final class PortalSessionReader {
    private let configuration: AppConfiguration
    private let transport: HTTPTransporting
    private let logger: AppLogger
    private let endpoints: PortalEndpoints

    init(configuration: AppConfiguration, transport: HTTPTransporting, logger: AppLogger) {
        self.configuration = configuration
        self.transport = transport
        self.logger = logger
        self.endpoints = PortalEndpoints(configuration: configuration)
    }

    func snapshot(username: String, sourceIP: String) async -> PortalSessionSnapshot {
        let page = await pageContext(sourceIP: sourceIP)
        let fact = await sessionFact(username: username, sourceIP: sourceIP)
        let runtime = await runtimeSettings(page: page, fact: fact, sourceIP: sourceIP)
        return PortalSessionSnapshot(fact: fact, runtime: runtime, page: page)
    }

    func verifyLogin(username: String, sourceIP: String) async -> Bool? {
        var sawDefinitiveMismatch = false
        for delay in [UInt64(0), 350_000_000, 900_000_000] {
            if delay > 0 {
                do { try await Task.sleep(nanoseconds: delay) } catch { return nil }
            }
            let fact = await sessionFact(username: username, sourceIP: sourceIP)
            if fact.matches(
                username: username,
                sourceIP: sourceIP,
                accountPrefix: configuration.auth.accountPrefix
            ) { return true }
            if fact.state == .offline || fact.state == .online { sawDefinitiveMismatch = true }
        }
        return sawDefinitiveMismatch ? false : nil
    }

    func sessionFact(username: String, sourceIP: String) async -> PortalSessionFact {
        let status = await fetchStatus(sourceIP: sourceIP)
        return await sessionFact(username: username, sourceIP: sourceIP, status: status)
    }

    func logoutVerificationState(username: String, sourceIP: String) async -> PortalSessionState {
        let status = await fetchStatus(sourceIP: sourceIP)
        if status.readable, status.declaredOnline == false {
            return .offline
        }
        if status.readable, status.declaredOnline == true {
            var fact = PortalSessionFact()
            fact.state = .online
            fact.account = status.account.trimmingCharacters(in: .whitespacesAndNewlines)
            fact.ip = IPv4CIDR.normalized(status.ip)
            if fact.matches(
                username: username,
                sourceIP: sourceIP,
                accountPrefix: configuration.auth.accountPrefix
            ) {
                return .online
            }
        }
        return await sessionFact(username: username, sourceIP: sourceIP, status: status).state
    }

    private func sessionFact(
        username: String,
        sourceIP: String,
        status: PortalStatusResult
    ) async -> PortalSessionFact {
        let configuredAccount = PortalAccountNormalizer.normalize(
            username,
            prefix: configuration.auth.accountPrefix
        )
        let statusAccount = PortalAccountNormalizer.normalize(
            status.account,
            prefix: configuration.auth.accountPrefix
        )
        let expectedAccount = configuredAccount.isEmpty ? statusAccount : configuredAccount
        let expectedIP = status.ip.isEmpty ? IPv4CIDR.normalized(sourceIP) : status.ip
        let onlineList = await fetchOnlineList(
            expectedAccount: expectedAccount,
            expectedIP: expectedIP,
            sourceIP: sourceIP
        )

        var fact = PortalSessionFact()
        // Keep the status endpoint's observed account when it supplies one so
        // an online session belonging to a different user cannot be mistaken
        // for the requested account.  The configured username remains the
        // query identity used for account-wide device counting.
        fact.account = statusAccount.isEmpty ? expectedAccount : statusAccount
        fact.ip = IPv4CIDR.normalized(expectedIP)
        fact.vlan = status.vlan.isEmpty ? "0" : status.vlan
        fact.acIP = status.acIP
        fact.acName = status.acName
        fact.statusWasReadable = status.readable
        fact.onlineListWasReadable = onlineList.readable
        fact.exactOnlineRecordPresent = onlineList.readable ? onlineList.exactRecord != nil : nil
        fact.onlineDeviceCount = onlineList.deviceCount
        fact.onlineDeviceLimit = CampusOnlineDevicePolicy.dormLimit

        if let record = onlineList.exactRecord {
            let recordAccount = PortalAccountNormalizer.normalize(
                PortalCodec.string(record, keys: ["user_account"]),
                prefix: configuration.auth.accountPrefix
            )
            let recordIP = IPv4CIDR.normalized(PortalCodec.string(record, keys: ["online_ip"]))
            if !recordAccount.isEmpty { fact.account = recordAccount }
            if !recordIP.isEmpty { fact.ip = recordIP }
            if fact.acIP.isEmpty {
                fact.acIP = IPv4CIDR.dottedAddress(fromLittleEndianPortalInteger: record["nas_ip"])
            }
        }

        let statusMAC = PortalCodec.normalizedMAC(status.mac)
        let recordMAC = PortalCodec.normalizedMAC(
            onlineList.exactRecord.map { PortalCodec.string($0, keys: ["online_mac"]) } ?? ""
        )
        // Only server-reported values are eligible for logout. Never replace
        // these with a physical or private MAC read from the local interface.
        fact.mac = PortalCodec.nonSentinelMAC(recordMAC)
        if fact.mac.isEmpty { fact.mac = PortalCodec.nonSentinelMAC(statusMAC) }
        if fact.mac.isEmpty { fact.mac = statusMAC.isEmpty ? recordMAC : statusMAC }

        if status.declaredOnline == false {
            fact.state = .offline
        } else if status.declaredOnline == true {
            fact.state = .online
        } else if onlineList.exactRecord != nil {
            fact.state = .online
        } else if onlineList.readable, !expectedAccount.isEmpty, !expectedIP.isEmpty {
            fact.state = .offline
        } else {
            fact.state = .unknown
        }
        return fact
    }

    private func pageContext(sourceIP: String) async -> PortalPageContext {
        guard let url = endpoints.pageURL else { return PortalPageContext() }
        let text = await fetchText(url, sourceIP: sourceIP)
        return PortalPageContext(
            url: url,
            text: text,
            variables: PortalCodec.pageVariables(text),
            declaredLogoutURL: PortalCodec.declaredLogoutURL(pageURL: url, pageText: text)
        )
    }

    private func fetchStatus(sourceIP: String) async -> PortalStatusResult {
        guard let url = endpoints.drcom("chkstatus") else { return PortalStatusResult() }
        guard let dictionary = await fetchDictionary(
            url,
            query: ["callback": "dr1002"],
            sourceIP: sourceIP
        ) else { return PortalStatusResult() }

        let rawIP = PortalCodec.string(dictionary, keys: ["v46ip", "ss5", "v4ip", "olip"])
        let rawMAC = PortalCodec.string(dictionary, keys: ["ss4", "olmac"])
        return PortalStatusResult(
            readable: true,
            declaredOnline: PortalCodec.boolean(dictionary["result"]),
            account: PortalCodec.string(dictionary, keys: ["uid", "user_account", "account"]),
            ip: IPv4CIDR.normalized(rawIP),
            mac: PortalCodec.normalizedMAC(rawMAC),
            vlan: PortalCodec.string(dictionary, keys: ["vlanid", "cvid", "pvid"]),
            acIP: IPv4CIDR.normalized(PortalCodec.string(dictionary, keys: ["wlanacip", "AC", "opip"])),
            acName: PortalCodec.string(dictionary, keys: ["wlanacname"])
        )
    }

    private func fetchOnlineList(
        expectedAccount: String,
        expectedIP: String,
        sourceIP: String
    ) async -> PortalOnlineListResult {
        guard let url = endpoints.portalAPI("online_list"),
              let dictionary = await fetchDictionary(
                  url,
                  query: ["callback": "dr9999"],
                  sourceIP: sourceIP
              ),
              let records = dictionary["list"] as? [[String: Any]] else {
            return PortalOnlineListResult()
        }
        let account = PortalAccountNormalizer.normalize(
            expectedAccount,
            prefix: configuration.auth.accountPrefix
        )
        let ip = IPv4CIDR.normalized(expectedIP)
        guard !account.isEmpty else {
            return PortalOnlineListResult(readable: true, exactRecord: nil, deviceCount: nil)
        }

        let normalizedAccounts = records.map {
            PortalAccountNormalizer.normalize(
                PortalCodec.string($0, keys: ["user_account", "username"]),
                prefix: configuration.auth.accountPrefix
            )
        }
        // A row without an account cannot be proven to belong to somebody
        // else. Treat the entire count as unknown instead of under-counting
        // and risking a fourth login.
        guard normalizedAccounts.allSatisfy({ !$0.isEmpty }) else {
            return PortalOnlineListResult(readable: true, exactRecord: nil, deviceCount: nil)
        }
        let accountRecords = zip(records, normalizedAccounts).compactMap { record, normalized in
            normalized == account ? record : nil
        }
        let exact = accountRecords.first {
            !ip.isEmpty
                && IPv4CIDR.normalized(PortalCodec.string($0, keys: ["online_ip"])) == ip
        }

        // Prefer a non-sentinel server MAC as the device identity.  If the
        // portal does not report one, a valid server IP is a conservative
        // fallback.  A matching record with neither value makes the total
        // unknowable instead of silently under-counting active devices.
        var identities = Set<String>()
        var macBackedIPs = Set<String>()
        var fallbackIPs = [String]()
        var reliable = true
        for record in accountRecords {
            let mac = PortalCodec.nonSentinelMAC(
                PortalCodec.string(record, keys: ["online_mac"])
            )
            let recordIP = IPv4CIDR.normalized(
                PortalCodec.string(record, keys: ["online_ip"])
            )
            if !mac.isEmpty {
                identities.insert("mac:\(mac)")
                if !recordIP.isEmpty, recordIP != "0.0.0.0" {
                    macBackedIPs.insert(recordIP)
                }
                continue
            }
            if !recordIP.isEmpty, recordIP != "0.0.0.0" {
                fallbackIPs.append(recordIP)
            } else {
                reliable = false
            }
        }
        // A portal may expose the same device twice, once with a server MAC
        // and once with only its IP.  MAC-backed records win; otherwise that
        // second row would be counted as an extra device.
        for ip in fallbackIPs where !macBackedIPs.contains(ip) {
            identities.insert("ip:\(ip)")
        }
        return PortalOnlineListResult(
            readable: true,
            exactRecord: exact,
            deviceCount: reliable
                ? min(identities.count, CampusOnlineDevicePolicy.dormLimit)
                : nil
        )
    }

    private func runtimeSettings(
        page: PortalPageContext,
        fact: PortalSessionFact,
        sourceIP: String
    ) async -> PortalRuntimeSettings {
        guard let url = endpoints.portalAPI("page/loadConfig") else { return PortalRuntimeSettings() }
        let ip = fact.ip.isEmpty ? IPv4CIDR.normalized(sourceIP) : fact.ip
        let query = [
            "callback": "dr1003",
            "program_index": "",
            "wlan_vlan_id": fact.vlan,
            "wlan_user_ip": Data(ip.utf8).base64EncodedString(),
            "wlan_user_ipv6": "",
            "wlan_user_ssid": "",
            "wlan_user_areaid": "",
            "wlan_ac_ip": Data(fact.acIP.utf8).base64EncodedString(),
            "wlan_ap_mac": "",
            "gw_id": "",
        ]
        guard let root = await fetchDictionary(url, query: query, sourceIP: sourceIP),
              let data = root["data"] as? [String: Any] else { return PortalRuntimeSettings() }
        return PortalRuntimeSettings(
            unbindMAC: PortalCodec.integer(data["un_bind_mac"]) != 0,
            registerMode: PortalCodec.integer(data["register_mode"]),
            ispUnbindSuffix: PortalCodec.integer(data["isp_unbind_suffix"]) != 0,
            acLogout: PortalCodec.integer(data["ac_logout"]),
            checkOnlineMethod: PortalCodec.integer(data["check_online_method"]),
            loginMethod: PortalCodec.integer(
                data["login_method"],
                default: Int(configuration.auth.loginMethod) ?? 1
            )
        )
    }

    private func fetchDictionary(
        _ url: URL,
        query: [String: String],
        sourceIP: String
    ) async -> [String: Any]? {
        do {
            let response = try await transport.get(
                url,
                query: query,
                headers: endpoints.headers(),
                timeout: TimeInterval(configuration.auth.timeoutSeconds),
                sourceIP: sourceIP.isEmpty ? nil : sourceIP
            )
            guard (200..<300).contains(response.statusCode) else { return nil }
            return PortalCodec.dictionary(PortalCodec.parseJSONP(response.bodyText))
        } catch {
            logger.info("门户会话事实读取失败 endpoint=\(url.path) reason=\(safeError(error))")
            return nil
        }
    }

    private func fetchText(_ url: URL, sourceIP: String) async -> String {
        do {
            let response = try await transport.get(
                url,
                query: [:],
                headers: endpoints.headers(refererURL: url),
                timeout: TimeInterval(configuration.auth.timeoutSeconds),
                sourceIP: sourceIP.isEmpty ? nil : sourceIP
            )
            return (200..<300).contains(response.statusCode) ? response.bodyText : ""
        } catch {
            logger.info("门户页面读取失败 endpoint=\(url.path) reason=\(safeError(error))")
            return ""
        }
    }

    private func safeError(_ error: Error) -> String {
        String(error.localizedDescription.replacingOccurrences(of: "\n", with: " ").prefix(120))
    }
}
