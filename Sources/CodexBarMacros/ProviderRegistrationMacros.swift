import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

private enum ProviderMacroError {
    struct Message: DiagnosticMessage {
        let message: String
        let diagnosticID: MessageID
        let severity: DiagnosticSeverity
    }

    static func unsupportedTarget(_ context: some MacroExpansionContext, node: SyntaxProtocol, macro: String) {
        context.diagnose(Diagnostic(
            node: node,
            message: Message(
                message: "@\(macro) must be attached to a struct, class, or enum.",
                diagnosticID: MessageID(domain: "CodexBarMacros", id: "unsupported_target"),
                severity: .error)))
    }

    static func missingDescriptor(_ context: some MacroExpansionContext, node: SyntaxProtocol, typeName: String) {
        context.diagnose(Diagnostic(
            node: node,
            message: Message(
                message: "\(typeName) must declare static let descriptor or static func makeDescriptor() " +
                    "to use @ProviderDescriptorRegistration.",
                diagnosticID: MessageID(domain: "CodexBarMacros", id: "missing_descriptor"),
                severity: .error)))
    }

    static func missingMakeDescriptor(_ context: some MacroExpansionContext, node: SyntaxProtocol, typeName: String) {
        context.diagnose(Diagnostic(
            node: node,
            message: Message(
                message: "\(typeName) must declare static func makeDescriptor() to use @ProviderDescriptorDefinition.",
                diagnosticID: MessageID(domain: "CodexBarMacros", id: "missing_make_descriptor"),
                severity: .error)))
    }

    static func duplicateDescriptor(_ context: some MacroExpansionContext, node: SyntaxProtocol, typeName: String) {
        context.diagnose(Diagnostic(
            node: node,
            message: Message(
                message: "\(typeName) already declares descriptor; remove @ProviderDescriptorDefinition.",
                diagnosticID: MessageID(domain: "CodexBarMacros", id: "duplicate_descriptor"),
                severity: .error)))
    }

    static func missingInit(_ context: some MacroExpansionContext, node: SyntaxProtocol, typeName: String) {
        context.diagnose(Diagnostic(
            node: node,
            message: Message(
                message: "\(typeName) must provide an init() to use @ProviderImplementationRegistration.",
                diagnosticID: MessageID(domain: "CodexBarMacros", id: "missing_init"),
                severity: .error)))
    }
}

private enum ProviderMacroIntrospection {
    static func typeDecl(from declaration: some DeclSyntaxProtocol) -> (decl: DeclGroupSyntax, name: String)? {
        if let decl = declaration.as(StructDeclSyntax.self) { return (decl, decl.name.text) }
        if let decl = declaration.as(ClassDeclSyntax.self) { return (decl, decl.name.text) }
        if let decl = declaration.as(EnumDeclSyntax.self) { return (decl, decl.name.text) }
        return nil
    }

    static func hasStaticDescriptor(in decl: DeclGroupSyntax) -> Bool {
        for member in decl.memberBlock.members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }
            guard self.isStatic(varDecl.modifiers) else { continue }
            for binding in varDecl.bindings {
                guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
                if pattern.identifier.text == "descriptor" { return true }
            }
        }
        return false
    }

    static func hasMakeDescriptor(in decl: DeclGroupSyntax) -> Bool {
        for member in decl.memberBlock.members {
            guard let funcDecl = member.decl.as(FunctionDeclSyntax.self) else { continue }
            guard self.isStatic(funcDecl.modifiers) else { continue }
            if funcDecl.name.text == "makeDescriptor" { return true }
        }
        return false
    }

    static func hasAccessibleInit(in decl: DeclGroupSyntax) -> Bool {
        if self.hasZeroArgInit(in: decl) { return true }
        if decl.is(EnumDeclSyntax.self) { return false }
        return self.canSynthesizeDefaultInit(in: decl)
    }

    private static func hasZeroArgInit(in decl: DeclGroupSyntax) -> Bool {
        for member in decl.memberBlock.members {
            guard let initDecl = member.decl.as(InitializerDeclSyntax.self) else { continue }
            let params = initDecl.signature.parameterClause.parameters
            if params.isEmpty { return true }
            let allDefaulted = params.allSatisfy { $0.defaultValue != nil }
            if allDefaulted { return true }
        }
        return false
    }

    private static func canSynthesizeDefaultInit(in decl: DeclGroupSyntax) -> Bool {
        for member in decl.memberBlock.members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }
            guard !self.isStatic(varDecl.modifiers) else { continue }
            for binding in varDecl.bindings {
                if binding.accessorBlock != nil { continue }
                if binding.initializer == nil { return false }
            }
        }
        return true
    }

    private static func isStatic(_ modifiers: DeclModifierListSyntax?) -> Bool {
        guard let modifiers else { return false }
        return modifiers.contains { $0.name.tokenKind == .keyword(.static) }
    }
}

public struct ProviderDescriptorRegistrationMacro: PeerMacro {
    public static func expansion(
        of _: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext) throws -> [DeclSyntax]
    {
        guard let (decl, typeName) = ProviderMacroIntrospection.typeDecl(from: declaration) else {
            ProviderMacroError.unsupportedTarget(
                context,
                node: Syntax(declaration),
                macro: "ProviderDescriptorRegistration")
            return []
        }

        let hasDescriptor = ProviderMacroIntrospection.hasStaticDescriptor(in: decl)
        let hasMakeDescriptor = ProviderMacroIntrospection.hasMakeDescriptor(in: decl)
        guard hasDescriptor || hasMakeDescriptor else {
            ProviderMacroError.missingDescriptor(context, node: Syntax(declaration), typeName: typeName)
            return []
        }

        let registerName = "_CodexBarDescriptorRegistration_\(typeName)"
        return [
            DeclSyntax(
                "private let \(raw: registerName) = ProviderDescriptorRegistry.register(\(raw: typeName).descriptor)"),
        ]
    }
}

public struct ProviderDescriptorDefinitionMacro: MemberMacro {
    public static func expansion(
        of _: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext) throws -> [DeclSyntax]
    {
        guard let (decl, typeName) = ProviderMacroIntrospection.typeDecl(from: declaration) else {
            ProviderMacroError.unsupportedTarget(
                context,
                node: Syntax(declaration),
                macro: "ProviderDescriptorDefinition")
            return []
        }

        if ProviderMacroIntrospection.hasStaticDescriptor(in: decl) {
            ProviderMacroError.duplicateDescriptor(context, node: Syntax(declaration), typeName: typeName)
            return []
        }

        guard ProviderMacroIntrospection.hasMakeDescriptor(in: decl) else {
            ProviderMacroError.missingMakeDescriptor(context, node: Syntax(declaration), typeName: typeName)
            return []
        }

        return [DeclSyntax("public static let descriptor: ProviderDescriptor = Self.makeDescriptor()")]
    }
}

public struct ProviderImplementationRegistrationMacro: PeerMacro {
    public static func expansion(
        of _: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext) throws -> [DeclSyntax]
    {
        guard let (decl, typeName) = ProviderMacroIntrospection.typeDecl(from: declaration) else {
            ProviderMacroError.unsupportedTarget(
                context,
                node: Syntax(declaration),
                macro: "ProviderImplementationRegistration")
            return []
        }

        guard ProviderMacroIntrospection.hasAccessibleInit(in: decl) else {
            ProviderMacroError.missingInit(context, node: Syntax(declaration), typeName: typeName)
            return []
        }

        let registerName = "_CodexBarImplementationRegistration_\(typeName)"
        return [
            DeclSyntax(
                "private let \(raw: registerName) = ProviderImplementationRegistry.register(\(raw: typeName)())"),
        ]
    }
}

@main
struct CodexBarMacroPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        ProviderDescriptorRegistrationMacro.self,
        ProviderDescriptorDefinitionMacro.self,
        ProviderImplementationRegistrationMacro.self,
    ]
}
