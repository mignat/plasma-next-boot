function parseEntryName(rawName) {
  var name = rawName;
  var efiPath = "";

  // efibootmgr separates name from device path with a tab
  var tabIndex = rawName.indexOf("\t");
  if (tabIndex !== -1) {
    name = rawName.substring(0, tabIndex).trim();
    efiPath = rawName.substring(tabIndex + 1).trim();
  }

  // Some firmware embeds the device path inline after the name
  else {
    var pathMatch = rawName.match(
      /^(.+?)\s+((?:HD|BBS|PciRoot|File|VenHw|VenMedia|UsbClass|Fv|ACPI)\(.*)$/,
    );
    if (pathMatch) {
      name = pathMatch[1].trim();
      efiPath = pathMatch[2].trim();
    }

    // Catch trailing File(\EFI\...) or backslash EFI paths
    else {
      var fileMatch = rawName.match(/^(.+?)\s+((?:File\()?\\EFI\\.+)$/i);
      if (fileMatch) {
        name = fileMatch[1].trim();
        efiPath = fileMatch[2].trim();
      } else {
        name = name.trim();
      }
    }
  }

  // Strip "UEFI: " prefix since we only boot UEFI
  name = name.replace(/^UEFI:\s*/i, "");

  return { name: name, efiPath: efiPath };
}

function bootEntryIcon(name) {
  var lower = name.toLowerCase();

  if (lower.indexOf("windows") !== -1)
    return "distributor-logo-windows-symbolic";

  if (lower.indexOf("ubuntu") !== -1) return "distributor-logo-ubuntu-symbolic";
  if (lower.indexOf("debian") !== -1) return "distributor-logo-debian-symbolic";
  if (lower.indexOf("fedora") !== -1) return "distributor-logo-fedora-symbolic";
  if (lower.indexOf("arch") !== -1)
    return "distributor-logo-archlinux-symbolic";
  if (lower.indexOf("opensuse") !== -1 || lower.indexOf("suse") !== -1)
    return "distributor-logo-opensuse-symbolic";
  if (lower.indexOf("manjaro") !== -1)
    return "distributor-logo-manjaro-symbolic";
  if (lower.indexOf("pop") !== -1 && lower.indexOf("os") !== -1)
    return "distributor-logo-pop-os-symbolic";
  if (lower.indexOf("mint") !== -1)
    return "distributor-logo-linux-mint-symbolic";
  if (lower.indexOf("gentoo") !== -1) return "distributor-logo-gentoo-symbolic";
  if (lower.indexOf("void") !== -1) return "distributor-logo-void-symbolic";
  if (lower.indexOf("nixos") !== -1) return "distributor-logo-nixos-symbolic";
  if (lower.indexOf("linux") !== -1) return "os-linux-symbolic";

  if (
    lower.indexOf("usb") !== -1 ||
    lower.indexOf("removable") !== -1 ||
    lower.indexOf("flash") !== -1 ||
    lower.indexOf("thumb") !== -1
  )
    return "drive-removable-media-usb-symbolic";

  if (
    lower.indexOf("network") !== -1 ||
    lower.indexOf("pxe") !== -1 ||
    lower.indexOf("ipv4") !== -1 ||
    lower.indexOf("ipv6") !== -1 ||
    lower.indexOf("http boot") !== -1 ||
    lower.indexOf("uefi: pxe") !== -1 ||
    lower.indexOf("lan") !== -1
  )
    return "network-wired-symbolic";

  if (
    lower.indexOf("cd-rom") !== -1 ||
    lower.indexOf("cd/dvd") !== -1 ||
    lower.indexOf("dvd") !== -1 ||
    lower.indexOf("optical") !== -1 ||
    lower.indexOf("cdrom") !== -1
  )
    return "media-optical-symbolic";

  if (lower.indexOf("shell") !== -1) return "utilities-terminal-symbolic";

  if (
    lower.indexOf("firmware") !== -1 ||
    lower.indexOf("setup") !== -1 ||
    lower.indexOf("bios") !== -1
  )
    return "preferences-system-symbolic";

  // Return a generic hard disk icon as fallback when no specific icon is found
  // This ensures that even if the current theme doesn't have a specific icon,
  // we still show something meaningful to the user
  return "drive-harddisk-symbolic";
}

function isUefiOsDuplicate(name) {
  return /^UEFI OS(\s*\(.*\))?$/.test(name.trim());
}

function parseCustomNames(configStr) {
  try {
    return JSON.parse(configStr || "{}");
  } catch (e) {
    return {};
  }
}

function cleanupConfig(validBootNums, customOrder, hiddenEntries, customNames) {
  var validSet = {};
  var i;
  for (i = 0; i < validBootNums.length; i++) validSet[validBootNums[i]] = true;

  // Remove stale boot numbers from custom order
  var cleanOrder = "";
  if (customOrder) {
    var orderParts = customOrder.split(",");
    var kept = [];
    for (i = 0; i < orderParts.length; i++) {
      var num = orderParts[i].trim();
      if (num !== "" && validSet[num]) kept.push(num);
    }
    cleanOrder = kept.join(",");
  }

  // Remove stale boot numbers from hidden list
  var cleanHidden = "";
  if (hiddenEntries) {
    var hiddenParts = hiddenEntries.split(",");
    var keptHidden = [];
    for (i = 0; i < hiddenParts.length; i++) {
      var hnum = hiddenParts[i].trim();
      if (hnum !== "" && validSet[hnum]) keptHidden.push(hnum);
    }
    cleanHidden = keptHidden.join(",");
  }

  // Remove stale boot numbers from custom names
  var namesObj = parseCustomNames(customNames);
  var cleanNames = {};
  for (var key in namesObj) {
    if (namesObj.hasOwnProperty(key) && validSet[key])
      cleanNames[key] = namesObj[key];
  }

  return {
    customOrder: cleanOrder,
    hiddenEntries: cleanHidden,
    customNames: JSON.stringify(cleanNames),
    changed:
      cleanOrder !== (customOrder || "") ||
      cleanHidden !== (hiddenEntries || "") ||
      JSON.stringify(cleanNames) !== (customNames || "{}"),
  };
}

function applyCustomOrder(entries, orderStr) {
  if (!orderStr || orderStr === "") return entries;

  var order = orderStr.split(",");
  var entryMap = {};
  var i;

  for (i = 0; i < entries.length; i++)
    entryMap[entries[i].bootNum] = entries[i];

  var ordered = [];
  for (i = 0; i < order.length; i++) {
    var num = order[i].trim();
    if (entryMap[num]) {
      ordered.push(entryMap[num]);
      delete entryMap[num];
    }
  }

  for (i = 0; i < entries.length; i++) {
    if (entryMap[entries[i].bootNum]) ordered.push(entries[i]);
  }

  return ordered;
}
