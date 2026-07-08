/**
 * @name FakeDeafen
 * @author hyyven
 * @authorId 449282863582412850
 * @description Fake deafen (and/or fake mute) yourself. Others see you as deafened/muted while you can still hear and talk. Toggle with a button in the account panel or a keybind (Ctrl+Shift+Q).
 * @version 1.0.0
 * @source https://github.com/hyyven/FakeDeafen
 */

module.exports = class FakeDeafen {
    constructor(meta) {
        this.meta = meta;
        this.api = new BdApi(meta.name);

        this.enabled = false;

        this.defaultSettings = {
            fakeDeafen: true,
            fakeMute: false,
            showButton: true,
            enableKeybind: true
        };
        this.settings = Object.assign({}, this.defaultSettings);

        // Set of React re-render callbacks so the toolbar button updates on toggle.
        this.listeners = new Set();

        // Reference to the socket instance we've patched so we can re-patch on reconnect.
        this.patchedSocket = null;
        this.unpatchSocket = null;

        this.handleKeyDown = this.handleKeyDown.bind(this);
    }

    // ---------------------------------------------------------------------
    // Webpack module lookups (equivalents of Vencord's findByProps / findComponentByCodeLazy)
    // ---------------------------------------------------------------------

    getSocketModule() {
        return BdApi.Webpack.getByKeys("getSocket");
    }

    getChannelStore() {
        return BdApi.Webpack.getByKeys("getChannel", "getDMFromUserId");
    }

    getSelectedChannelStore() {
        return BdApi.Webpack.getByKeys("getVoiceChannelId");
    }

    getMediaEngineStore() {
        return BdApi.Webpack.getByKeys("isDeaf", "isMute");
    }

    getPanelButton() {
        const { Filters, getModule } = BdApi.Webpack;
        // Discord's small round account-panel button (mic / deafen / settings).
        return (
            getModule(Filters.byStrings(".GREEN,positionKeyStemOverride:"), { searchExports: true }) ||
            getModule(Filters.byStrings("positionKeyStemOverride"), { searchExports: true }) ||
            null
        );
    }

    // ---------------------------------------------------------------------
    // Core: gateway voice-state interception
    // ---------------------------------------------------------------------

    // Patches the gateway socket so outgoing voice-state updates (op 4) are
    // rewritten to report self_mute / self_deaf when Fake Deafen is enabled.
    // Re-patches automatically if Discord swaps the socket (e.g. on reconnect).
    ensureSocketPatched() {
        const wsModule = this.getSocketModule();
        if (!wsModule) {
            console.error("[FakeDeafen] WebSocket gateway module not found");
            return false;
        }

        const socket = wsModule.getSocket?.();
        if (!socket) return false;

        if (this.patchedSocket === socket && this.unpatchSocket) return true;

        if (this.unpatchSocket) {
            this.unpatchSocket();
            this.unpatchSocket = null;
        }

        const self = this;
        this.patchedSocket = socket;
        this.unpatchSocket = BdApi.Patcher.instead(this.meta.name, socket, "send", (thisObject, args, original) => {
            const [op, data] = args;
            // op code 4 = voiceStateUpdate
            if (op === 4 && self.enabled && data) {
                if (self.settings.fakeMute) data.self_mute = true;
                if (self.settings.fakeDeafen) data.self_deaf = true;
            }
            return original.apply(thisObject, args);
        });

        return true;
    }

    // Sends a fresh voice-state update so the change takes effect immediately
    // instead of waiting for the next natural update.
    refreshVoiceState() {
        const ChannelStore = this.getChannelStore();
        const SelectedChannelStore = this.getSelectedChannelStore();
        const wsModule = this.getSocketModule();
        const MediaEngineStore = this.getMediaEngineStore();

        let missing = 0;
        if (!wsModule) {
            console.error("[FakeDeafen] WebSocket gateway not found");
            missing += 1;
        }
        if (!SelectedChannelStore) {
            console.error("[FakeDeafen] SelectedChannelStore not found");
            missing += 1;
        }
        if (missing > 0) return;

        const socket = wsModule.getSocket?.();
        const channelId = SelectedChannelStore.getVoiceChannelId();
        const channel = channelId ? ChannelStore?.getChannel(channelId) : null;

        if (socket && channelId) {
            try {
                // op code 4 = voiceStateUpdate. The patched send() above will
                // additionally force the fake flags while enabled.
                socket.send(4, {
                    guild_id: channel?.guild_id ?? null,
                    channel_id: channelId,
                    self_mute: (this.enabled && this.settings.fakeMute) || (MediaEngineStore?.isMute() ?? false),
                    self_deaf: (this.enabled && this.settings.fakeDeafen) || (MediaEngineStore?.isDeaf() ?? false),
                    self_video: false,
                    flags: 0
                });
                console.log("[FakeDeafen] voice state updated to", this.enabled ? "fake deafen" : "normal");
            } catch (error) {
                console.error("[FakeDeafen] failed to update voice state:", error);
            }
        }
    }

    toggle() {
        this.enabled = !this.enabled;
        this.ensureSocketPatched();
        this.refreshVoiceState();
        this.notify();
        BdApi.UI.showToast(`Fake Deafen ${this.enabled ? "enabled" : "disabled"}`, {
            type: this.enabled ? "success" : "info"
        });
    }

    notify() {
        for (const listener of this.listeners) {
            try {
                listener();
            } catch (e) {
                /* ignore stale listeners */
            }
        }
    }

    handleKeyDown(event) {
        if (this.settings.enableKeybind && event.ctrlKey && event.shiftKey && event.code === "KeyQ") {
            event.preventDefault();
            this.toggle();
        }
    }

    // ---------------------------------------------------------------------
    // Toolbar button (account panel)
    // ---------------------------------------------------------------------

    buildIcon() {
        const React = BdApi.React;
        const color = this.enabled ? "#ed4245" : "currentColor";

        const children = [
            React.createElement("rect", { key: "bar", x: 6, y: 8, width: 20, height: 4, rx: 2, fill: color }),
            React.createElement("rect", { key: "band", x: 11, y: 3, width: 10, height: 8, rx: 3, fill: color })
        ];

        if (this.enabled) {
            children.push(
                React.createElement("line", { key: "l1", x1: 7, y1: 18, x2: 13, y2: 24, stroke: color, strokeWidth: 2 }),
                React.createElement("line", { key: "l2", x1: 13, y1: 18, x2: 7, y2: 24, stroke: color, strokeWidth: 2 }),
                React.createElement("line", { key: "l3", x1: 19, y1: 18, x2: 25, y2: 24, stroke: color, strokeWidth: 2 }),
                React.createElement("line", { key: "l4", x1: 25, y1: 18, x2: 19, y2: 24, stroke: color, strokeWidth: 2 }),
                React.createElement("path", { key: "mouth", d: "M14 23c1-1 3-1 4 0", stroke: color, strokeWidth: 2, strokeLinecap: "round" })
            );
        } else {
            children.push(
                React.createElement("circle", { key: "c1", cx: 10, cy: 21, r: 4, stroke: color, strokeWidth: 2, fill: "none" }),
                React.createElement("circle", { key: "c2", cx: 22, cy: 21, r: 4, stroke: color, strokeWidth: 2, fill: "none" }),
                React.createElement("path", { key: "mouth", d: "M14 21c1 1 3 1 4 0", stroke: color, strokeWidth: 2, strokeLinecap: "round" })
            );
        }

        return React.createElement("svg", { width: 20, height: 20, viewBox: "0 0 32 32", fill: "none" }, children);
    }

    // A React component subscribing to toggle updates so the icon/color refreshes.
    get ButtonComponent() {
        if (this._ButtonComponent) return this._ButtonComponent;

        const self = this;
        const React = BdApi.React;

        this._ButtonComponent = function FakeDeafenButton(props) {
            const [, forceUpdate] = React.useReducer(x => x + 1, 0);

            React.useEffect(() => {
                self.listeners.add(forceUpdate);
                return () => self.listeners.delete(forceUpdate);
            }, []);

            const PanelButton = self.getPanelButton();

            try {
                if (PanelButton) {
                    return React.createElement(PanelButton, {
                        tooltipText: self.enabled ? "Disable Fake Deafen" : "Enable Fake Deafen",
                        icon: () => self.buildIcon(),
                        role: "switch",
                        "aria-checked": self.enabled,
                        redGlow: self.enabled,
                        plated: props?.nameplate != null,
                        onClick: () => self.toggle()
                    });
                }

                // Fallback: a plain button if the internal component can't be found.
                return React.createElement(
                    "button",
                    {
                        className: "fake-deafen-fallback-button",
                        role: "switch",
                        type: "button",
                        "aria-checked": self.enabled,
                        "aria-label": self.enabled ? "Disable Fake Deafen" : "Enable Fake Deafen",
                        onClick: () => self.toggle(),
                        style: {
                            background: "none",
                            border: "none",
                            cursor: "pointer",
                            display: "flex",
                            alignItems: "center",
                            padding: "4px"
                        }
                    },
                    self.buildIcon()
                );
            } catch (e) {
                console.error("[FakeDeafen] button render failed:", e);
                return null;
            }
        };

        return this._ButtonComponent;
    }

    // Injects the toggle button into the account panel next to the mic/deafen
    // buttons. Best-effort: the plugin stays fully usable via keybind/settings
    // even if Discord's internals change and the button can't be placed.
    patchAccountPanel() {
        const { Webpack, Patcher, Utils, React } = BdApi;
        const { Filters } = Webpack;
        const self = this;

        let mod = null;
        let key = null;

        const candidates = ["AccountConnected", "renderNameZone", "AccountPanel"];
        for (const token of candidates) {
            try {
                const found = Webpack.getWithKey(Filters.byStrings(token));
                if (found && found[0] && found[1]) {
                    mod = found[0];
                    key = found[1];
                    break;
                }
            } catch (e) {
                /* try next candidate */
            }
        }

        if (!mod || !key) {
            console.warn(
                "[FakeDeafen] Could not locate the account panel component. " +
                "The toolbar button is unavailable, but Fake Deafen still works via the keybind (Ctrl+Shift+Q) and settings."
            );
            return;
        }

        Patcher.after(this.meta.name, mod, key, (that, args, ret) => {
            if (!self.settings.showButton) return ret;

            try {
                // Locate the row that already holds the account-panel buttons and
                // prepend our toggle to it.
                const container = Utils.findInTree(
                    ret,
                    node =>
                        Array.isArray(node?.children) &&
                        node.children.some(child => child?.props?.role === "switch" || typeof child?.props?.onClick === "function"),
                    { walkable: ["props", "children"] }
                );

                const button = React.createElement(self.ButtonComponent, {
                    key: "fake-deafen-toggle",
                    nameplate: args?.[0]?.nameplate
                });

                if (container && Array.isArray(container.children)) {
                    container.children.unshift(button);
                } else if (Array.isArray(ret?.props?.children)) {
                    ret.props.children.unshift(button);
                }
            } catch (e) {
                console.error("[FakeDeafen] failed to inject the toolbar button:", e);
            }

            return ret;
        });
    }

    // ---------------------------------------------------------------------
    // Settings
    // ---------------------------------------------------------------------

    getSettingsPanel() {
        const self = this;
        return BdApi.UI.buildSettingsPanel({
            settings: [
                {
                    type: "switch",
                    id: "fakeDeafen",
                    name: "Fake Deafen",
                    note: "While enabled, appear deafened to everyone else — but you can still hear.",
                    value: this.settings.fakeDeafen
                },
                {
                    type: "switch",
                    id: "fakeMute",
                    name: "Fake Mute",
                    note: "While enabled, appear muted to everyone else — but you can still talk.",
                    value: this.settings.fakeMute
                },
                {
                    type: "switch",
                    id: "showButton",
                    name: "Show Panel Button",
                    note: "Show a toggle button in the account panel (bottom-left, next to mic/deafen).",
                    value: this.settings.showButton
                },
                {
                    type: "switch",
                    id: "enableKeybind",
                    name: "Enable Keybind",
                    note: "Toggle Fake Deafen with Ctrl+Shift+Q.",
                    value: this.settings.enableKeybind
                }
            ],
            onChange: (_, id, value) => {
                self.settings[id] = value;
                self.api.Data.save("settings", self.settings);
                if (self.enabled) self.refreshVoiceState();
                self.notify();
            }
        });
    }

    // ---------------------------------------------------------------------
    // Lifecycle
    // ---------------------------------------------------------------------

    start() {
        const saved = this.api.Data.load("settings");
        this.settings = Object.assign({}, this.defaultSettings, saved || {});

        this.ensureSocketPatched();
        this.patchAccountPanel();

        window.addEventListener("keydown", this.handleKeyDown);
    }

    stop() {
        window.removeEventListener("keydown", this.handleKeyDown);

        // Restore the real voice state before we drop the socket patch.
        if (this.enabled) {
            this.enabled = false;
            this.refreshVoiceState();
        }

        BdApi.Patcher.unpatchAll(this.meta.name);
        this.unpatchSocket = null;
        this.patchedSocket = null;

        this.notify();
    }
};
