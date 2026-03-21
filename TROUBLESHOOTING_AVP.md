# Troubleshooting: Running SpatialSynesthesia on AVP / Simulator

The project **builds successfully** for visionOS. If you cannot run or test it, follow these steps.

---

## Option 1: Run on visionOS Simulator (on your Mac)

The visionOS Simulator runs on your Mac and simulates Apple Vision Pro.

### Steps

1. **Open the project** in Xcode: `SpatialSynesthesia.xcodeproj` (inside the `SpatialSynesthesia` folder).

2. **Select the Simulator destination**
   - Click the run destination dropdown next to the scheme (shows "SpatialSynesthesia")
   - Choose **"Apple Vision Pro"** under **visionOS Simulators**
   - If it’s missing: **Xcode → Settings → Platforms** and install the visionOS platform

3. **Run the app**
   - Press **⌘R** or click the Run button
   - The Simulator window should open and show the Vision Pro environment
   - Your app appears in the Simulator’s app grid; open it from there

### If the Simulator doesn’t start

- **Apple Silicon required:** visionOS Simulator only runs on Apple Silicon Macs
- **Install platform:** Xcode → Settings → Platforms → Download visionOS Simulator
- **Reset Simulator:** Device → Erase All Content and Settings
- **Restart Xcode** after installing or changing platforms

---

## Option 2: Run on a Physical Apple Vision Pro

### Requirements

1. **Apple Vision Pro** with visionOS 26+ (or matching your deployment target)
2. **USB-C cable** to connect the headset to your Mac
3. **Apple ID** with a free or paid developer account
4. **Development team** configured for code signing

### Steps

1. **Connect the device**
   - Plug the Vision Pro into your Mac with USB-C
   - Put on the headset and **Trust** the computer if prompted

2. **Set a Development Team**
   - In Xcode, select the **SpatialSynesthesia** project in the navigator
   - Select the **SpatialSynesthesia** target
   - Open **Signing & Capabilities**
   - Check **Automatically manage signing**
   - Choose your **Team** from the dropdown (your Apple ID)
   - Resolve any provisioning/signing errors shown by Xcode

3. **Choose your Vision Pro as the destination**
   - In the run destination dropdown, select your connected **Apple Vision Pro** (by name)
   - If it doesn’t appear: unplug and reconnect, confirm the device is trusted, and check Xcode → Window → Devices and Simulators

4. **Run the app**
   - Press **⌘R**
   - Approve installation on the device if asked
   - The app should install and launch on the headset

### If you get “Signing requires a development team”

- In **Signing & Capabilities**, select your **Team**
- If no team is listed: Xcode → Settings → Accounts → add your Apple ID
- With a free account, you may need to trust the developer certificate on the device the first time

---

## Quick checks

| Issue | Action |
|-------|--------|
| Build fails | Check the error in the Issue Navigator; fix and rebuild |
| “No such device” / no destination | Install the visionOS platform and/or connect the Vision Pro |
| Simulator is black or frozen | Device → Erase All Content and Settings, then run again |
| App installs but crashes on device | Check the device console (Window → Devices and Simulators → your device → Open Console) |
| App opens but shows nothing | Immersive space may be behind the window; try the “Enter Immersive” control or look for the volumetric window |

---

## Scheme and destination summary

- **Scheme:** SpatialSynesthesia
- **Simulator destination:** Apple Vision Pro (visionOS Simulators)
- **Device destination:** Your connected Apple Vision Pro (when available)
