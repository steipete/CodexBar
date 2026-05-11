import Foundation
import Testing
@testable import CodexBarCore

struct KiloOrganizationTests {
    @Test
    func `decodes from canonical Kilo profile payload`() throws {
        let json = #"""
        { "id": "org_123", "name": "Acme Corp", "role": "owner" }
        """#
        let data = Data(json.utf8)
        let org = try JSONDecoder().decode(KiloOrganization.self, from: data)
        #expect(org.id == "org_123")
        #expect(org.name == "Acme Corp")
        #expect(org.role == "owner")
    }

    @Test
    func `decodes when role missing`() throws {
        let json = #"""
        { "id": "org_xyz", "name": "No Role Org" }
        """#
        let data = Data(json.utf8)
        let org = try JSONDecoder().decode(KiloOrganization.self, from: data)
        #expect(org.role == nil)
    }

    @Test
    func `equality covers all stored fields`() {
        let a = KiloOrganization(id: "org_1", name: "A", role: "member")
        let b = KiloOrganization(id: "org_1", name: "A", role: "member")
        let differentRole = KiloOrganization(id: "org_1", name: "A", role: "owner")
        #expect(a == b)
        #expect(a != differentRole)
    }
}
