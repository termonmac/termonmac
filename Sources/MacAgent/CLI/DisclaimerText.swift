#if os(macOS)
import Foundation

struct DisclaimerText {
    /// Increment when disclaimer text is modified.
    static let revision = 8

    static let text = """
    ════════════════════════════════════════════════
      ADDITIONAL TERMS OF SERVICE & DISCLAIMER
    ════════════════════════════════════════════════

    These terms supplement the Apple Licensed
    Application End User License Agreement (EULA).
    In the event of a conflict, Apple's EULA shall
    prevail.

    By using TermOnMac and its iOS companion
    RemoteDev (collectively, "the Software"), you
    acknowledge and agree to the following
    additional terms:

    ── TERMS OF SERVICE ───────────────────────

     1. SERVICE MODIFICATIONS
        The developers reserve the right to modify,
        suspend, or discontinue any aspect of the
        Software at any time, including token
        allocations, usage limits, features, and
        pricing. Continued use after changes
        constitutes acceptance of the modified terms.

     2. TOKEN USAGE
        Tokens or credits are granted at the sole
        discretion of the developers. Tokens have no
        monetary value, are non-transferable, and may
        not be exchanged for cash. Token quantities,
        expiration periods, and schedules may be
        adjusted at any time without prior notice.

     3. ACCEPTABLE USE
        You agree to use the Software only for lawful
        purposes and shall not circumvent usage limits
        or abuse token distribution mechanisms.

     4. ACCOUNT TERMINATION
        The developers may suspend or terminate your
        access at any time, with or without cause.
        Where practicable, reasonable notice will be
        provided. Upon termination, remaining tokens
        are forfeited.

     5. PRIVACY
        The Software collects only the minimum
        data necessary to provide the service,
        including connection metadata (IP address,
        user agent) and usage analytics linked to
        your account. This agent stores a local
        input history log (up to 32 KB per session)
        in .remotedev/input-log/; this data never
        leaves your devices. Personal data is not
        sold to third parties. Refer to the Privacy
        Policy for details. Account deletion takes
        effect after a 30-day grace period.

     6. AGE REQUIREMENT
        You must be at least 18 years of age to use
        this Software. By accepting these terms, you
        confirm that you meet this requirement.

     7. THIRD-PARTY SERVICES
        The Software integrates with third-party
        services (GitHub, Google for authentication;
        relay servers for connections). Your use of
        these services is subject to their respective
        terms. The developers are not responsible for
        third-party service availability.

     8. GOVERNING LAW
        These terms are governed by the laws of the
        Republic of China (Taiwan). Disputes shall be
        subject to the jurisdiction of the Taiwan
        Taipei District Court.

     9. CHANGES TO TERMS
        These terms may be updated at any time. For
        material changes, notice will be provided
        within the Software at least 14 days before
        the changes take effect. Continued use after
        an update constitutes acceptance.

    ── SUBSCRIPTION TERMS ─────────────────────

    10. SUBSCRIPTION PLANS
        The Software offers optional paid subscription
        plans (e.g., Pro and Premium) that provide
        additional features and higher usage quotas.

    11. PAYMENT AND BILLING
        Payment is charged to your Apple ID account at
        confirmation of purchase. Subscriptions renew
        automatically unless turned off at least 24
        hours before the current period ends. You can
        manage subscriptions in App Store settings.

    12. FREE TRIALS AND PROMOTIONAL OFFERS
        If offered, any unused portion of a free trial
        is forfeited when you purchase a subscription.
        Promotional pricing applies only for the
        initial period stated.

    13. REFUNDS
        All purchases are processed through Apple.
        Refund requests are handled per Apple's refund
        policy. The developers do not process refunds
        directly.

    14. CONTACT
        For questions regarding these terms, your
        subscription, or your account, contact us at
        quietlight.work@gmail.com.

    ── DISCLAIMER ─────────────────────────────

    15. REMOTE ACCESS RISKS
        The Software grants significant control over
        this Mac via a remote terminal session.
        Unauthorized access may result in data loss,
        system modification, or other damage.

    16. ENCRYPTION LIMITATIONS
        Although end-to-end encryption is used
        (Curve25519 ECDH + AES-256-GCM), no
        cryptographic system is guaranteed to be
        completely secure.

    17. CREDENTIAL SECURITY
        You are solely responsible for safeguarding
        your room credentials and device access.

    18. DATA LOSS
        Commands executed through the remote terminal
        may modify or delete files. The developers are
        not responsible for any data loss.

    19. NO WARRANTY
        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT
        WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
        INCLUDING BUT NOT LIMITED TO THE WARRANTIES
        OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
        PURPOSE, AND NON-INFRINGEMENT.

    20. LIMITATION OF LIABILITY
        IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
        HOLDERS BE LIABLE FOR ANY INDIRECT, INCIDENTAL,
        SPECIAL, CONSEQUENTIAL, OR PUNITIVE DAMAGES,
        INCLUDING BUT NOT LIMITED TO LOSS OF PROFITS,
        DATA, OR USE, ARISING OUT OF OR IN CONNECTION
        WITH THE USE OF THIS SOFTWARE.

    ════════════════════════════════════════════════
    """
}
#endif
