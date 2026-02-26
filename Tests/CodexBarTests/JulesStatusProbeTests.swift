import CodexBarCore
import Foundation
import Testing

@Suite
struct JulesStatusProbeTests {
    @Test
    func parsesMultipleSessionsWithHeader() throws {
        let output = """
         ID                             Description                             Repo            Last active            Status       
         49456769777706412…  another test session                                kirtangajjar/Code…  2s ago              In Progress  
         59979648718544086…  test session for codexbar                           kirtangajjar/Code…  32s ago             Completed    
         45493069977919456…  Implement Jules integration                         kirtangajjar/Code…  52m43s ago          Completed    
        """
        let snap = try JulesStatusProbe.parse(text: output, email: "test@example.com", plan: "Paid")
        #expect(snap.activeSessions == 3)
        #expect(snap.isAuthenticated == true)
        #expect(snap.accountEmail == "test@example.com")
        #expect(snap.accountPlan == "Paid")
        
        let usage = snap.toUsageSnapshot()
        let primary = try #require(usage.primary)
        #expect(primary.usedPercent == 3.0) 
        #expect(primary.remainingPercent == 97.0)
        #expect(primary.resetDescription == "3/100 (24h rolling)")
        
        let identity = try #require(usage.identity)
        #expect(identity.accountEmail == "test@example.com")
        #expect(identity.loginMethod == "Paid")
    }

    @Test
    func handlesNoSessionsFound() throws {
        let output = "No sessions found"
        let snap = try JulesStatusProbe.parse(text: output)
        #expect(snap.activeSessions == 0)
        #expect(snap.isAuthenticated == true)
        
        let usage = snap.toUsageSnapshot()
        let primary = try #require(usage.primary)
        #expect(primary.usedPercent == 0.0)
        #expect(primary.remainingPercent == 100.0)
    }

    @Test
    func throwsNotLoggedInOnAuthError() {
        let output = "Error: failed to list tasks: Trying to make a GET request without a valid client (did you forget to login?)"
        #expect(throws: JulesStatusProbeError.notLoggedIn) {
            try JulesStatusProbe.parse(text: output)
        }
    }

    @Test
    func handlesEmptyOutputAsZeroSessions() throws {
        let snap = try JulesStatusProbe.parse(text: "")
        #expect(snap.activeSessions == 0)
        #expect(snap.isAuthenticated == true)
    }

    @Test
    func preservesRawText() throws {
        let output = """
        session-1
        session-2
        """
        let snap = try JulesStatusProbe.parse(text: output)
        #expect(snap.rawText == output)
    }
}
