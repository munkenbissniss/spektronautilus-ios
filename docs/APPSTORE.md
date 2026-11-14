# Getting it to people

1. **Apple Developer Program**: about 99 USD per year. Needed for TestFlight and the App Store. (A free account can run the app on your own phone for 7 days at a time.)
2. **TestFlight first**: Xcode → Product → Archive → Distribute → App Store Connect. Invite testers by e-mail; no review for internal testers.
3. **App Store review**, things to prepare:
   - Privacy: the app collects nothing; microphone is used on-device (VJ sound), "Local network" for the receiver page. Fill in the privacy questionnaire accordingly ("Data not collected").
   - **Donations**: Apple requires in-app purchase for digital goods, but donations to a developer are a grey area. Safest: no donate button inside the app (only on the website), or use a link that opens Safari and says nothing about unlocking features. Everything in the app stays free.
   - **Minimum functionality (guideline 4.2)**: the app is a web wrapper, which reviewers dislike. Argue with the native parts: hardware video conversion, MIDI, external-screen output, offline use.
   - Screenshots (6.7" and 6.1"), description, keywords, support URL, age rating.
4. **Updates**: the site is bundled, so content changes need a new build. (Apple allows updating web content that runs in the app's WebView, but bundled code is safer for review.)
5. Sideloading alternatives: AltStore/TestFlight links.
