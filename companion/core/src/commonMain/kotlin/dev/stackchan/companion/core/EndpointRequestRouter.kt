package dev.stackchan.companion.core

class EndpointRequestRouter(
    private val settingsRepository: SettingsRepository = SettingsRepository(),
    private val trustedEndpointRegistry: TrustedEndpointRegistry = TrustedEndpointRegistry(),
    private val brainOwnerCoordinator: BrainOwnerCoordinator = BrainOwnerCoordinator(trustedEndpointRegistry),
    private val diagnosticsReporter: DiagnosticsReporter = DiagnosticsReporter(
        settingsRepository = settingsRepository,
        trustedEndpointRegistry = trustedEndpointRegistry,
        brainOwnerCoordinator = brainOwnerCoordinator,
    ),
    private val onSettingsChanged: (SettingsRepository) -> Unit = {},
    private val onTrustedEndpointsChanged: (TrustedEndpointRegistry) -> Unit = {},
) {
    fun handle(message: BridgeMessage): BridgeMessage? =
        when (message) {
            is ClaimBrain -> brainOwnerCoordinator.claim(message)
            is ReleaseBrain -> brainOwnerCoordinator.release(message)
            is Heartbeat -> message.endpointId?.takeIf { it.isNotBlank() }?.let {
                brainOwnerCoordinator.heartbeat(it)
            }
            is SettingsGet -> settingsRepository.handleGet(message)
            is SettingsSet -> handleSettingsSet(message)
            is TrustedEndpoints -> trustedEndpointRegistry.trustedEndpoints()
            is ForgetEndpoint -> handleForgetEndpoint(message)
            is DiagnosticsRequest -> diagnosticsReporter.snapshot(message)
            else -> null
        }

    private fun handleSettingsSet(message: SettingsSet): SettingsResult {
        val outcome = settingsRepository.handleSet(message)
        if (outcome.result.ok) {
            onSettingsChanged(settingsRepository)
        }
        return outcome.result
    }

    private fun handleForgetEndpoint(message: ForgetEndpoint): ForgetEndpointResult {
        val result = trustedEndpointRegistry.forget(message.endpointId)
        if (result.ok) {
            brainOwnerCoordinator.clearIfForgotten(message.endpointId)
            onTrustedEndpointsChanged(trustedEndpointRegistry)
        }
        return result
    }
}
