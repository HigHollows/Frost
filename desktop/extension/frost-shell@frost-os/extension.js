/* FROST Shell extension — targets GNOME Shell 45+ (ES module extensions).
 *
 * UNVERIFIED: written against the documented GNOME 45+ extension API
 * from spec/reference, but never run against a real gnome-shell process
 * (no Wayland/GNOME runtime available in the environment this was
 * written in). Treat as a solid starting point to test and fix on real
 * hardware/VM, not as confirmed-working code — see DESKTOP.README.md.
 *
 * Scope, deliberately: this does NOT reimplement a dock, quick-settings
 * panel, or notification system — GNOME Shell already has all three
 * (Quick Settings native since GNOME 43; the dock comes from the
 * separate, well-established "Dash to Dock" extension, configured by
 * frost-desktop.sh, not rewritten here). This extension only adds the
 * things that are genuinely FROST-specific: a Steam Mode quick toggle,
 * a small panel indicator, and the hidden easter egg keybinding.
 */

import GObject from 'gi://GObject';
import St from 'gi://St';
import Gio from 'gi://Gio';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as QuickSettings from 'resource:///org/gnome/shell/ui/quickSettings.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';

const EASTER_EGG_LINES = [
    'Minimalist means every element earns its place.',
    'Frozen point: 0°C, 32°F, and exactly one distro.',
    'You found it. Most people never right-click the snowflake.',
];

function runDetached(argv) {
    try {
        const proc = Gio.Subprocess.new(argv, Gio.SubprocessFlags.NONE);
        proc.wait_async(null, () => {});
    } catch (e) {
        logError(e, `frost-shell: failed to launch ${argv.join(' ')}`);
    }
}

const SteamModeToggle = GObject.registerClass(
class SteamModeToggle extends QuickSettings.QuickToggle {
    _init() {
        super._init({
            title: 'Steam Mode',
            iconName: 'applications-games-symbolic',
            toggleMode: true,
        });
        this.connect('clicked', () => this._onToggled());
    }

    _onToggled() {
        if (this.checked)
            runDetached(['steam', '-bigpicture']);
        else
            runDetached(['steam', '-shutdown']);
    }
});

const FrostIndicator = GObject.registerClass(
class FrostIndicator extends PanelMenu.Button {
    _init() {
        super._init(0.0, 'FROST', false);

        const icon = new St.Icon({
            icon_name: 'weather-snow-symbolic',
            style_class: 'system-status-icon frost-panel-icon',
        });
        this.add_child(icon);

        const versionItem = new PopupMenu.PopupMenuItem('FROST OS', {reactive: false});
        this.menu.addMenuItem(versionItem);
        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        const settingsItem = new PopupMenu.PopupMenuItem('Settings');
        settingsItem.connect('activate', () => runDetached(['gnome-control-center']));
        this.menu.addMenuItem(settingsItem);
    }
});

export default class FrostShellExtension extends Extension {
    enable() {
        this._settings = this.getSettings();

        this._indicator = new FrostIndicator();
        Main.panel.addToStatusArea(`${this.uuid}-indicator`, this._indicator, 1, 'right');

        // Quick Settings API (GNOME 43+): register an external indicator
        // rather than rebuilding the panel — this is the supported
        // extension point, not a private/internal hack.
        this._steamToggle = new SteamModeToggle();
        Main.panel.statusArea.quickSettings.addExternalIndicator(this._steamToggle);

        Main.wm.addKeybinding(
            'easter-egg-keybinding',
            this._settings,
            Meta.KeyBindingFlags.NONE,
            Shell.ActionMode.NORMAL,
            () => this._revealEasterEgg()
        );
    }

    disable() {
        Main.wm.removeKeybinding('easter-egg-keybinding');

        this._steamToggle?.destroy();
        this._steamToggle = null;

        this._indicator?.destroy();
        this._indicator = null;

        this._settings = null;
    }

    _revealEasterEgg() {
        const line = EASTER_EGG_LINES[Math.floor(Math.random() * EASTER_EGG_LINES.length)];
        Main.notify('❄ FROST', line);
    }
}
