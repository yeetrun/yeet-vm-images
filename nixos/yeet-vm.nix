{ lib
, pkgs
, ...
}:

let
  ghosttyTerminfo =
    pkgs.runCommand "xterm-ghostty-terminfo" { nativeBuildInputs = [ pkgs.ncurses ]; }
      ''
        mkdir -p "$out/share/terminfo"
        tic -x -o "$out/share/terminfo" ${./assets/xterm-ghostty.terminfo}
        test -e "$out/share/terminfo/x/xterm-ghostty"
      '';

  guestReady = pkgs.writeShellScript "yeet-guest-ready" ''
    set -eu

    ssh_ready() {
      ss -H -ltn 'sport = :22' | grep -q .
    }

    report_ip() {
      ip -o -4 addr show scope global | awk '
        $2 != "lo" {
          split($4, ip, "/")
          print $2 " " ip[1]
          exit
        }
      '
    }

    emit_ready() {
      report="$1"
      printf 'yeet-ready %s\n' "$report" >/dev/ttyS0
      command -v logger >/dev/null && logger "yeet-ready $report" || true
    }

    for _ in $(seq 1 120); do
      report="$(report_ip || true)"
      if [ -n "$report" ] && ssh_ready; then
        emit_ready "$report"
        exit 0
      fi
      sleep 0.25
    done

    echo yeet-ready-timeout >/dev/ttyS0
    exit 1
  '';

  disabledModprobeServices =
    lib.genAttrs [
      "modprobe@configfs"
      "modprobe@drm"
      "modprobe@efi_pstore"
      "modprobe@fuse"
    ]
      (_: {
        enable = lib.mkDefault false;
      });
in
{
  system.stateVersion = "26.05";
  system.nixos.tags = [ "yeet-vm" ];

  boot = {
    initrd.enable = false;
    kernelModules = lib.mkForce [ ];
    loader.grub.enable = false;
    loader.systemd-boot.enable = false;
    tmp.cleanOnBoot = true;
  };

  fileSystems."/" = {
    device = "/dev/vda";
    fsType = "ext4";
    neededForBoot = true;
  };

  networking = {
    firewall.enable = false;
    hostName = lib.mkDefault "yeet-vm";
    useDHCP = false;
    useNetworkd = true;
  };

  services.resolved.enable = true;

  users.mutableUsers = true;
  users.users.nixos = {
    isNormalUser = true;
    createHome = true;
    description = "Yeet VM user";
    extraGroups = [ "wheel" ];
    home = "/home/nixos";
    shell = pkgs.bashInteractive;
  };

  security.sudo.wheelNeedsPassword = false;
  security.sudo-rs.wheelNeedsPassword = false;

  services.openssh = {
    enable = true;
    authorizedKeysFiles = [
      "%h/.ssh/authorized_keys"
      "/etc/ssh/authorized_keys.d/%u"
      "/etc/yeet-vm/authorized_keys.d/%u"
    ];
    openFirewall = false;
    settings = {
      KbdInteractiveAuthentication = false;
      PasswordAuthentication = false;
      PermitRootLogin = "prohibit-password";
      UseDns = false;
      X11Forwarding = false;
    };
  };

  environment = {
    systemPackages = with pkgs; [
      bashInteractive
      coreutils
      curl
      file
      gitMinimal
      htop
      iproute2
      iptables
      jq
      nftables
      openssh
      procps
      sudo
      vim
      wget
      ghosttyTerminfo
    ];
    pathsToLink = [ "/share/terminfo" ];
    etc.terminfo.enable = lib.mkForce false;
  };

  programs.bash = {
    completion.enable = true;
    interactiveShellInit = ''
      if [ -t 1 ]; then
        export CLICOLOR=1
        alias ls='ls --color=auto'
        alias grep='grep --color=auto'
        alias egrep='egrep --color=auto'
        alias fgrep='fgrep --color=auto'
        PS1='\[\e[01;32m\]\u@\h\[\e[00m\]:\[\e[01;34m\]\w\[\e[00m\]\$ '
      fi
    '';
  };

  nix = {
    package = pkgs.nixVersions.latest;
    nixPath = [
      "nixpkgs=flake:nixpkgs"
      "nixos-config=/etc/nixos/configuration.nix"
    ];
    settings.experimental-features = [
      "nix-command"
      "flakes"
    ];
  };

  documentation = {
    doc.enable = false;
    info.enable = false;
    man.enable = false;
    nixos.enable = false;
  };

  systemd = {
    network.enable = true;
    tmpfiles.rules = [
      "d /etc/yeet-vm 0755 root root -"
      "d /etc/yeet-vm/authorized_keys.d 0755 root root -"
      "d /etc/yeet-vm/systemd-network 0755 root root -"
      "d /dev/net 0755 root root -"
      "c /dev/net/tun 0666 root root 10:200"
    ];

    services = disabledModprobeServices // {
      yeet-metadata-hostname = {
        description = "Apply yeet VM metadata hostname";
        wantedBy = [ "sysinit.target" ];
        before = [
          "network-pre.target"
          "systemd-networkd.service"
        ];
        unitConfig.DefaultDependencies = false;
        path = [ pkgs.nettools ];
        script = ''
          if [ -r /etc/yeet-vm/hostname ]; then
            name="$(head -n1 /etc/yeet-vm/hostname | tr -d '[:space:]')"
            if [ -n "$name" ]; then
              hostname "$name"
            fi
          fi
        '';
        serviceConfig.Type = "oneshot";
      };

      yeet-networkd-metadata = {
        description = "Install yeet VM networkd metadata";
        wantedBy = [ "sysinit.target" ];
        before = [
          "network-pre.target"
          "systemd-networkd.service"
        ];
        unitConfig.DefaultDependencies = false;
        script = ''
          mkdir -p /run/systemd/network
          for network in /etc/yeet-vm/systemd-network/*.network; do
            if [ -e "$network" ]; then
              cp "$network" /run/systemd/network/
            fi
          done
        '';
        serviceConfig.Type = "oneshot";
      };

      sshd = {
        after = [
          "yeet-metadata-hostname.service"
          "yeet-networkd-metadata.service"
          "systemd-networkd.service"
        ];
        wants = [ "systemd-networkd.service" ];
      };

      yeet-grow-root = {
        description = "yeet grow root filesystem";
        wantedBy = [ "multi-user.target" ];
        after = [ "local-fs.target" ];
        before = [ "yeet-guest-ready.service" ];
        path = [
          pkgs.e2fsprogs
          pkgs.systemd
          pkgs.util-linux
        ];
        script = ''
          root_source="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
          root_fstype="$(findmnt -n -o FSTYPE / 2>/dev/null || true)"

          case "$root_source" in
            /dev/*) ;;
            *) exit 0 ;;
          esac

          if [ "$root_fstype" != "ext4" ]; then
            exit 0
          fi

          if resize2fs "$root_source"; then
            logger "yeet-grow-root complete $root_source" || true
            exit 0
          fi

          logger "yeet-grow-root failed $root_source" || true
          exit 0
        '';
        serviceConfig = {
          Type = "oneshot";
          Nice = 10;
          IOSchedulingClass = "idle";
        };
      };

      yeet-guest-ready = {
        description = "yeet-ready guest marker";
        wantedBy = [ "multi-user.target" ];
        after = [
          "sshd.service"
          "yeet-grow-root.service"
        ];
        wants = [
          "sshd.service"
          "yeet-grow-root.service"
        ];
        path = [
          pkgs.gawk
          pkgs.gnugrep
          pkgs.iproute2
          pkgs.systemd
        ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = guestReady;
        };
      };
    };
  };
}
