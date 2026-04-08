{ pkgs, lib, novnc-src, ... }:
let
  # ---------------------------------------------------------------------------
  # Helper: build a PATH string from a list of packages
  # ---------------------------------------------------------------------------
  mkPath = ps: lib.makeBinPath ps;

  # Packages needed inside VNC/desktop scripts
  desktopDeps = with pkgs; [
    tigervnc
    coreutils
    bash
    gnugrep
    gnused
    dbus
    xorg.xset
    xorg.xdpyinfo
    xorg.xinit       # needed by tigervnc vncserver wrapper
    xorg.xauth
    xfce.xfce4-session
    xfce.xfwm4
    xfce.xfce4-panel
    xfce.xfdesktop
    xfce.xfce4-settings
    xfce.xfce4-notifyd
    xfce.xfce4-terminal
    procps       # pgrep / pkill
    util-linux   # setsid
  ];

  # ---------------------------------------------------------------------------
  # Scripts
  # ---------------------------------------------------------------------------

  xstartup = pkgs.writeShellScript "xstartup" ''
    export PATH="${mkPath desktopDeps}:$PATH"
    dbus-launch startxfce4 &
    sleep 2
    xset s off
    xset -dpms
    xset s noblank
  '';

  startVnc = pkgs.writeShellScript "start-vnc" ''
    set -e
    export PATH="${mkPath desktopDeps}:$PATH"

    # Source credentials
    if [ -f /etc/cua/env ]; then
      set -a; source /etc/cua/env; set +a
    fi

    # Refuse to start with placeholder password
    if [ "$VNC_PW" = "PLACEHOLDER" ] || [ -z "$VNC_PW" ]; then
      echo "ERROR: VNC_PW not set, using default for testing"
      VNC_PW="testpass123"
    fi

    # Clean stale X lock files
    rm -f /tmp/.X1-lock /tmp/.X11-unix/X1

    # Create VNC password file
    mkdir -p /home/cua/.vnc
    echo "$VNC_PW" | vncpasswd -f > /home/cua/.vnc/passwd
    chmod 0600 /home/cua/.vnc/passwd

    # Start VNC server
    vncserver :1 \
      -xstartup ${xstartup} \
      -geometry ''${VNC_RESOLUTION:-1024x768} \
      -depth ''${VNC_COL_DEPTH:-24} \
      -rfbport 5901 \
      -localhost no \
      -SecurityTypes VncAuth \
      -AlwaysShared \
      -AcceptPointerEvents \
      -AcceptKeyEvents \
      -AcceptCutText \
      -SendCutText
  '';

  stopVnc = pkgs.writeShellScript "stop-vnc" ''
    export PATH="${mkPath desktopDeps}:$PATH"
    vncserver -kill :1 || true
  '';

  startNovnc = pkgs.writeShellScript "start-novnc" ''
    export PATH="${mkPath [ pkgs.python3Packages.websockify pkgs.coreutils ]}:$PATH"
    # Wait for VNC server to be ready
    sleep 5
    exec websockify --web ${novnc-src} 6901 localhost:5901
  '';

  startComputerServer = pkgs.writeShellScript "start-computer-server" ''
    set -e
    export PATH="${mkPath [ pkgs.coreutils pkgs.xorg.xdpyinfo pkgs.bash ]}:$PATH"

    # Source credentials
    if [ -f /etc/cua/env ]; then
      set -a; source /etc/cua/env; set +a
    fi
    export DISPLAY=:1

    # Wait for X server to be ready
    for i in $(seq 1 30); do
      if xdpyinfo -display :1 >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done

    exec /opt/cua/venv/bin/python -m computer_server --port 8000
  '';

  setupCuaApi = pkgs.writeShellScript "setup-cua-api" ''
    set -e
    export PATH="${mkPath (with pkgs; [ coreutils python3 bash gnugrep curl ])}:$PATH"

    # Check if venv exists AND has computer_server installed
    if /opt/cua/venv/bin/python -c 'import computer_server' 2>/dev/null; then
      echo "CUA API venv already set up, skipping"
      exit 0
    fi

    # Remove broken venv if it exists
    rm -rf /opt/cua/venv

    echo "Setting up CUA API server..."
    mkdir -p /opt/cua
    python3 -m venv /opt/cua/venv
    /opt/cua/venv/bin/pip install --upgrade pip uv
    /opt/cua/venv/bin/uv pip install --python /opt/cua/venv/bin/python cua-computer-server "cua-agent[all]" || {
      echo "WARNING: Full install failed, trying minimal install"
      /opt/cua/venv/bin/uv pip install --python /opt/cua/venv/bin/python cua-computer-server || true
    }

    chown -R cua:cua /opt/cua
    echo "CUA API setup complete"
  '';

  watchdogScript = pkgs.writeShellScript "cua-service-watchdog" ''
    export PATH="${mkPath (with pkgs; [ coreutils bash gnugrep curl systemd ])}:$PATH"
    ALERTMANAGER_URL="https://am.cua.ai"
    HOSTNAME=$(hostname)
    SERVICES=("cua-api" "cua-vnc" "cua-novnc")

    while true; do
      for svc in "''${SERVICES[@]}"; do
        if ! systemctl is-active --quiet "$svc.service"; then
          echo "WARNING: $svc is not running"
          # Post alert to alertmanager if reachable
          curl -sf -XPOST "$ALERTMANAGER_URL/api/v1/alerts" \
            -H "Content-Type: application/json" \
            -d "[{\"labels\":{\"alertname\":\"ContainerServiceDown\",\"severity\":\"warning\",\"service\":\"$svc\",\"container\":\"$HOSTNAME\",\"component\":\"cua-desktop\"},\"annotations\":{\"summary\":\"$svc is down on $HOSTNAME\"}}]" \
            2>/dev/null || true
        fi
      done
      sleep 30
    done
  '';

  # ---------------------------------------------------------------------------
  # XFCE config files (disable screensaver, power manager, lock screen)
  # ---------------------------------------------------------------------------

  xfce4SessionXml = ''
    <?xml version="1.0" encoding="UTF-8"?>
    <channel name="xfce4-session" version="1.0">
      <property name="general" type="empty">
        <property name="SaveOnExit" type="bool" value="false"/>
        <property name="AutoSave" type="bool" value="false"/>
      </property>
      <property name="compat" type="empty">
        <property name="LaunchGNOME" type="bool" value="false"/>
        <property name="LaunchKDE" type="bool" value="false"/>
      </property>
      <property name="splash" type="empty">
        <property name="Engine" type="string" value=""/>
      </property>
      <property name="shutdown" type="empty">
        <property name="LockScreen" type="bool" value="false"/>
        <property name="ShowSuspend" type="bool" value="false"/>
        <property name="ShowHibernate" type="bool" value="false"/>
      </property>
    </channel>
  '';

  xfce4PowerManagerXml = ''
    <?xml version="1.0" encoding="UTF-8"?>
    <channel name="xfce4-power-manager" version="1.0">
      <property name="xfce4-power-manager" type="empty">
        <property name="dpms-enabled" type="bool" value="false"/>
        <property name="blank-on-ac" type="int" value="0"/>
        <property name="dpms-on-ac-sleep" type="uint" value="0"/>
        <property name="dpms-on-ac-off" type="uint" value="0"/>
        <property name="lock-screen-suspend-hibernate" type="bool" value="false"/>
        <property name="inactivity-on-ac" type="uint" value="0"/>
        <property name="inactivity-sleep-mode-on-ac" type="uint" value="0"/>
      </property>
    </channel>
  '';

in
{
  nixpkgs.hostPlatform = "aarch64-linux";

  # ---------------------------------------------------------------------------
  # Comin – GitOps pull deployment
  # ---------------------------------------------------------------------------
  services.comin = {
    enable = true;
    hostname = "system-manager-test";
    remotes = [{
      name = "origin";
      url = "https://github.com/trycua/system-manager-test.git";
      branches.main.name = "main";
    }];
  };

  # ---------------------------------------------------------------------------
  # System packages
  # ---------------------------------------------------------------------------
  environment.systemPackages = with pkgs; [
    # VNC and display
    tigervnc

    # Desktop environment
    xfce.xfce4-session
    xfce.xfce4-terminal
    xfce.xfwm4
    xfce.xfce4-panel
    xfce.xfdesktop
    xfce.xfce4-settings
    xfce.xfce4-notifyd

    # X11 utilities
    xorg.xset
    xorg.xdpyinfo
    xorg.xauth
    xdotool
    xclip

    # Browser
    firefox

    # Python
    python3
    python3Packages.pip
    python3Packages.websockify

    # Development and utilities
    git
    curl
    wget
    jq
    htop
    unzip
    gnumake
    gcc

    # Media and interaction tools
    ffmpeg
    socat
    scrot

    # Core utilities
    coreutils
    bash
    gnugrep
    gnused
    dbus
    procps
    util-linux
  ];

  # ---------------------------------------------------------------------------
  # /etc files
  # ---------------------------------------------------------------------------
  environment.etc = {
    # CUA credentials / environment
    "cua/env" = {
      text = ''
        VNC_PW=testpassword
        VNC_RESOLUTION=1024x768
        VNC_COL_DEPTH=24
        CUA_API_KEY=test-api-key-for-development
      '';
      mode = "0644";
    };

    # XFCE session config
    "xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-session.xml" = {
      text = xfce4SessionXml;
    };

    # XFCE power manager config
    "xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-power-manager.xml" = {
      text = xfce4PowerManagerXml;
    };

    # Force IPv4 for apt (Incus bridge has no IPv6)
    "apt/apt.conf.d/99force-ipv4" = {
      text = ''Acquire::ForceIPv4 "true";'';
    };
  };

  # ---------------------------------------------------------------------------
  # Systemd services
  # ---------------------------------------------------------------------------
  systemd.services.cua-user-setup = {
    description = "Create CUA user and directories";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "cua-user-setup" ''
        export PATH="${mkPath (with pkgs; [ coreutils bash shadow util-linux ])}:$PATH"

        # Create cua group and user if they don't exist
        getent group cua >/dev/null || groupadd -g 1002 cua
        id cua &>/dev/null || useradd -m -u 1001 -g 1002 -s /bin/bash cua

        # Add to sudo group if it exists
        getent group sudo >/dev/null && usermod -aG sudo cua || true

        # Create required directories
        mkdir -p /home/cua/.vnc /home/cua/.cache/dconf /home/cua/.mozilla/firefox
        mkdir -p /home/cua/.config/xfce4/xfconf/xfce-perchannel-xml
        mkdir -p /home/cua/.config/autostart
        mkdir -p /home/cua/storage /home/cua/shared
        mkdir -p /opt/cua /etc/cua

        chown -R cua:cua /home/cua /opt/cua
        chmod 0700 /home/cua/.vnc
      '';
    };
    wantedBy = [ "system-manager.target" ];
  };

  systemd.services.cua-api-setup = {
    description = "CUA API Server Setup (pip venv)";
    after = [ "cua-user-setup.service" "network.target" ];
    requires = [ "cua-user-setup.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = setupCuaApi;
      TimeoutStartSec = "600";
    };
    wantedBy = [ "system-manager.target" ];
  };

  systemd.services.cua-vnc = {
    description = "CUA TigerVNC Server";
    after = [ "network.target" "cua-user-setup.service" ];
    requires = [ "cua-user-setup.service" ];
    serviceConfig = {
      Type = "forking";
      User = "cua";
      Group = "cua";
      EnvironmentFile = "/etc/cua/env";
      ExecStart = startVnc;
      ExecStop = stopVnc;
      Restart = "on-failure";
      RestartSec = 5;
    };
    wantedBy = [ "system-manager.target" ];
  };

  systemd.services.cua-novnc = {
    description = "CUA noVNC Web Client (port 6901)";
    after = [ "cua-vnc.service" ];
    requires = [ "cua-vnc.service" ];
    startLimitIntervalSec = 0;
    serviceConfig = {
      Type = "simple";
      User = "cua";
      Group = "cua";
      ExecStart = startNovnc;
      Restart = "always";
      RestartSec = 5;
    };
    wantedBy = [ "system-manager.target" ];
  };

  systemd.services.cua-api = {
    description = "CUA Computer-Use API Server (port 8000)";
    after = [ "network.target" "cua-vnc.service" "cua-api-setup.service" ];
    requires = [ "cua-api-setup.service" ];
    serviceConfig = {
      Type = "simple";
      User = "cua";
      Group = "cua";
      WorkingDirectory = "/opt/cua";
      EnvironmentFile = "/etc/cua/env";
      Environment = "DISPLAY=:1";
      ExecStart = startComputerServer;
      Restart = "on-failure";
      RestartSec = 5;
    };
    wantedBy = [ "system-manager.target" ];
  };

  systemd.services.cua-service-watchdog = {
    description = "CUA Service Watchdog";
    after = [ "cua-api.service" "cua-vnc.service" "cua-novnc.service" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = watchdogScript;
      Restart = "always";
      RestartSec = 10;
    };
    wantedBy = [ "system-manager.target" ];
  };
}
