package dev.stackchan.companion.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class CompanionIdentityTest {
    @Test
    fun privacyPolicyUsesCanonicalPublicHttpsUrl() {
        assertEquals(
            "https://robvanprod.github.io/stackchan_alive/privacy/",
            CompanionIdentity.privacyPolicyUrl,
        )
        assertTrue(CompanionIdentity.privacyPolicyUrl.startsWith("https://"))
    }
}
