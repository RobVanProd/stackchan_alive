package dev.stackchan.companion.core

private val shortCodePattern = Regex("^[A-Z0-9]{6}$")
private val fingerprintPattern = Regex("^sha256:[0-9a-f]{16,128}$")

data class PairingChallenge(
    val endpoint: DiscoveredEndpoint,
    val shortCode: String,
    val publicKeyFingerprint: String,
)

data class PairingConfirmation(
    val enteredShortCode: String,
    val displayedFingerprint: String,
    val priority: Int = 60,
    val autoConnect: Boolean = true,
)

data class PairingResult(
    val trustedEndpoint: TrustedEndpoint,
    val method: DiscoveryMethod,
)

fun normalizePairingShortCode(value: String): String =
    value
        .trim()
        .replace("-", "")
        .replace(" ", "")
        .uppercase()

fun normalizeSha256Fingerprint(value: String): String {
    val trimmed = value.trim().lowercase()
    val hex = if (trimmed.startsWith("sha256:")) {
        trimmed.removePrefix("sha256:")
    } else {
        trimmed
    }.replace(":", "").replace("-", "").replace(" ", "")
    return "sha256:$hex"
}

fun createPairingChallenge(
    endpoint: DiscoveredEndpoint,
    shortCode: String,
    publicKeyFingerprint: String,
): PairingChallenge {
    val normalizedCode = normalizePairingShortCode(shortCode)
    val normalizedFingerprint = normalizeSha256Fingerprint(publicKeyFingerprint)
    require(endpoint.endpointId.isNotBlank()) { "endpoint_id is required before pairing" }
    require(endpoint.endpointKind in setOf("pc", "android")) { "unsupported endpoint_kind: ${endpoint.endpointKind}" }
    require(endpoint.protocol == CompanionIdentity.protocol) { "unsupported protocol: ${endpoint.protocol}" }
    require(shortCodePattern.matches(normalizedCode)) { "pairing short code must be six base-36 characters" }
    require(fingerprintPattern.matches(normalizedFingerprint)) { "fingerprint must be sha256 hex" }
    return PairingChallenge(
        endpoint = endpoint,
        shortCode = normalizedCode,
        publicKeyFingerprint = normalizedFingerprint,
    )
}

fun confirmPairing(
    challenge: PairingChallenge,
    confirmation: PairingConfirmation,
): PairingResult {
    val enteredCode = normalizePairingShortCode(confirmation.enteredShortCode)
    val displayedFingerprint = normalizeSha256Fingerprint(confirmation.displayedFingerprint)
    require(enteredCode == challenge.shortCode) { "pairing short code does not match" }
    require(displayedFingerprint == challenge.publicKeyFingerprint) { "pairing fingerprint does not match" }
    require(confirmation.priority in 0..100) { "priority must be 0..100" }
    return PairingResult(
        trustedEndpoint = TrustedEndpoint(
            endpointId = challenge.endpoint.endpointId,
            endpointName = challenge.endpoint.endpointName,
            endpointKind = challenge.endpoint.endpointKind,
            publicKeyFingerprint = challenge.publicKeyFingerprint,
            priority = confirmation.priority,
            autoConnect = confirmation.autoConnect,
            capabilities = challenge.endpoint.capabilities,
            lastSeenMs = 0,
        ),
        method = challenge.endpoint.method,
    )
}
