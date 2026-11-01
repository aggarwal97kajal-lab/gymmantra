# Pilot signing key

`gymmantra-pilot.jks` signs the APKs built by GitHub Actions, so each new
APK installs as an update over the previous one. The password is in
`password.txt`. The repository is private; keep it that way.

Before publishing on the Play Store, create a new upload key that is not
stored in the repository and enrol in Play App Signing.
