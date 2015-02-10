{ config, lib, pkgs, ... }:

with lib;

let

  cfg = config.networking.wireless;
  configFile = "/etc/wpa_supplicant.conf";

  ifaces =
    cfg.interfaces ++
    optional (config.networking.WLANInterface != "") config.networking.WLANInterface;

  configFile_ = pkgs.writeText "wpa_supplicant.conf" (concatStrings (mapAttrsToList (name: value: ''
    network={
      ssid="${name}"
      ${optionalString (value.key != null) ''
        psk="${builtins.encryptString <nixos-store-key> value.key}"
      ''}
    }
  '') cfg.networks));

in

{

  ###### interface

  options = {

    networking.WLANInterface = mkOption {
      default = "";
      description = "Obsolete. Use <option>networking.wireless.interfaces</option> instead.";
    };

    networking.wireless = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to start <command>wpa_supplicant</command> to scan for
          and associate with wireless networks.  Note: NixOS currently
          does not generate <command>wpa_supplicant</command>'s
          configuration file, <filename>${configFile}</filename>.  You
          should edit this file yourself to define wireless networks,
          WPA keys and so on (see
          <citerefentry><refentrytitle>wpa_supplicant.conf</refentrytitle>
          <manvolnum>5</manvolnum></citerefentry>).
        '';
      };

      interfaces = mkOption {
        type = types.listOf types.string;
        default = [];
        example = [ "wlan0" "wlan1" ];
        description = ''
          The interfaces <command>wpa_supplicant</command> will use.  If empty, it will
          automatically use all wireless interfaces.
        '';
      };

      driver = mkOption {
        type = types.str;
        default = "nl80211,wext";
        description = "Force a specific wpa_supplicant driver.";
      };

      networks = mkOption {
        type = types.attrsOf types.optionSet;
        default = {};
        description = ''
          Definitions of known wireless networks.
        '';
        options =
          { config, ... }:
          { options = {

              keyManagement = mkOption {
                type = types.string;
                default = "WPA-PSK";
                description = ''
                  The key management protocol.
                '';
              };

              key = mkOption {
                type = types.nullOr types.string;
                default = null;
                example = "Hello world!";
                description = ''
                  The pre-shared key.
                '';
              };

            };

            config = {
              keyManagement = mkDefault (if config.key == null then "NONE" else "WPA-PSK");
            };
          };
      };

      userControlled = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Allow normal users to control wpa_supplicant through wpa_gui or wpa_cli.
            This is useful for laptop users that switch networks a lot.

            When you want to use this, make sure ${configFile} doesn't exist.
            It will be created for you.

            Currently it is also necessary to explicitly specify networking.wireless.interfaces.
          '';
        };

        group = mkOption {
          type = types.str;
          default = "wheel";
          example = "network";
          description = "Members of this group can control wpa_supplicant.";
        };
      };
    };
  };


  ###### implementation

  config = mkIf cfg.enable {

    environment.systemPackages =  [ pkgs.wpa_supplicant ];

    services.dbus.packages = [ pkgs.wpa_supplicant ];

    # FIXME: start a separate wpa_supplicant instance per interface.
    jobs.wpa_supplicant =
      { description = "WPA Supplicant";

        wantedBy = [ "network.target" ];

        path = [ pkgs.wpa_supplicant ];

        preStart = if cfg.userControlled.enable then ''
          mkdir -m 0700 -p /run/secret
          ${config.nix.package}/bin/nix-store --decrypt ${toString <nixos-store-key>} \
            ${configFile_} > /run/secret/wpa_supplicant.conf
        '' else ''
          if [ ! -s ${configFile} ]; then
            touch -a ${configFile}
            chmod 600 ${configFile}
            echo "ctrl_interface=DIR=/run/wpa_supplicant GROUP=${cfg.userControlled.group}" >> ${configFile}
            echo "update_config=1" >> ${configFile}
          fi
        '';

        script =
          ''
            ${if ifaces == [] then ''
              for i in $(cd /sys/class/net && echo *); do
                DEVTYPE=
                source /sys/class/net/$i/uevent
                if [ "$DEVTYPE" = "wlan" -o -e /sys/class/net/$i/wireless ]; then
                  ifaces="$ifaces''${ifaces:+ -N} -i$i"
                fi
              done
            '' else ''
              ifaces="${concatStringsSep " -N " (map (i: "-i${i}") ifaces)}"
            ''}
            exec wpa_supplicant -s -u -D${cfg.driver} -c ${if cfg.userControlled.enable then configFile else /run/secret/wpa_supplicant.conf} $ifaces
          '';
      };

    powerManagement.resumeCommands =
      ''
        ${config.systemd.package}/bin/systemctl try-restart wpa_supplicant
      '';

    assertions = [{ assertion = !cfg.userControlled.enable || cfg.interfaces != [];
                    message = "user controlled wpa_supplicant needs explicit networking.wireless.interfaces";}];

    # Restart wpa_supplicant when a wlan device appears or disappears.
    services.udev.extraRules =
      ''
        ACTION=="add|remove", SUBSYSTEM=="net", ENV{DEVTYPE}=="wlan", RUN+="${config.systemd.package}/bin/systemctl try-restart wpa_supplicant.service"
      '';

  };

}
