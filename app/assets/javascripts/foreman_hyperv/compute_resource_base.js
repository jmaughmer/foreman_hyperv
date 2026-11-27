function hypervDynamicMemoryChange(item) {
  var toIter = [
    '#host_compute_attributes_memory_maximum',
    '#host_compute_attributes_memory_minimum',
    '#compute_attribute_vm_attrs_memory_maximum',
    '#compute_attribute_vm_attrs_memory_minimum',
  ];

  if (item.checked) {
    for (var i = 0; i < toIter.length; ++i) {
      $(toIter[i]).removeAttr('disabled');
    }
  } else {
    for (var i = 0; i < toIter.length; ++i) {
      $(toIter[i]).attr('disabled', true);
    }
  }
}

function hypervHostChange(item) {
  console.log('Hyper-V host changed to ' + $(item).val());

  $('table.hyperv-host-info').hide();
  $('table.hyperv-host-info[data-host="'+$(item).val()+'"]').show();

  // PLG-59: which switches this node answers is a per-node fact the union
  // dropdown cannot carry, so the form asks the endpoint for the map and dims
  // what the chosen node is PROVEN to lack. Fail-open everywhere: an unknown
  // node, a failed fetch, a GUID the endpoint list does not carry — all leave
  // every option standing, with one line saying the node could not be
  // confirmed. The save-time gate in the model is the enforcement; this is
  // the early word.
  hypervFilterSwitchesForHost(item);
}

// The map is fetched once and reused while its key holds. The key is the
// resource plus the cluster the form currently names, because the map is a
// statement about that cluster's nodes; changing the cluster and then the
// host re-fetches. Requests carry a generation number: when a newer fetch
// has been asked for, an older in-flight response no longer speaks for the
// form and applies no dim (last REQUEST wins, not last RESPONSE).
var hypervSwitchHostsGen = 0;
function hypervSwitchHosts(hostSelect, done) {
  var url = $(hostSelect).data('hyperv-switch-hosts-url');
  if (!url) { done(null); return; }

  var $cluster = $(hostSelect).closest('form').find('select[name$="cluster_name]"]').first();
  var cluster = $cluster.length ? ($cluster.val() || '') : '';
  var key = url + '|' + cluster;

  if (window.hypervSwitchHostsCache && window.hypervSwitchHostsCache.key === key) {
    done(window.hypervSwitchHostsCache.info);
    return;
  }

  hypervSwitchHostsGen += 1;
  var gen = hypervSwitchHostsGen;
  $.ajax({
    url: url + (cluster ? '?cluster_name=' + encodeURIComponent(cluster) : ''),
    type: 'GET',
    dataType: 'json',
    success: function (data) {
      if (gen !== hypervSwitchHostsGen) { return; }
      var cr = (data && data.compute_resource) || {};
      window.hypervSwitchHostsCache = { key: key, info: { switchHosts: cr.switch_hosts || {}, endpointSwitches: cr.endpoint_switches || null } };
      done(window.hypervSwitchHostsCache.info);
    },
    error: function () {
      // Silence is not absence: the map is simply not held, and the caller
      // fails open. Nothing is cached for a failed read.
      if (gen !== hypervSwitchHostsGen) { return; }
      done(null);
    },
  });
}

function hypervFilterSwitchesForHost(hostSelect) {
  var $form = $(hostSelect).closest('form');
  var switchSelects = $form.find('select[name$="switch_id]"]');
  if (switchSelects.length === 0) { return; }

  var clear = function (note) {
    switchSelects.each(function () {
      var $select = $(this);
      $select.find('option').prop('disabled', false);
      $select.next('span.hyperv-switch-hosts-note').remove();
      if (note) {
        $select.after('<span class="hyperv-switch-hosts-note help-block">' + note + '</span>');
      }
    });
  };

  if (!$(hostSelect).data('hyperv-switch-hosts-url')) {
    // No endpoint wired (a resource the plugin did not render the hook for):
    // nothing to say.
    clear(null);
    return;
  }

  var note = __('Hyper-V switches at this node could not be confirmed.');

  hypervSwitchHosts(hostSelect, function (info) {
    var host = $(hostSelect).val();
    if (!info || !host) { clear(note); return; }

    var present = null;
    Object.keys(info.switchHosts).forEach(function (name) {
      if (String(name).toLowerCase() === String(host).toLowerCase()) {
        present = info.switchHosts[name];
      }
    });
    if (!Array.isArray(present)) { clear(note); return; }

    var presentLower = present.map(function (name) { return String(name).toLowerCase(); });
    var guidToName = {};
    if (Array.isArray(info.endpointSwitches)) {
      info.endpointSwitches.forEach(function (sw) { guidToName[String(sw.id)] = sw.name; });
    }

    clear(null);
    switchSelects.each(function () {
      $(this).find('option').each(function () {
        var guid = String($(this).attr('value') || '');
        var name = guidToName[guid];
        // A blank option, or a GUID the endpoint's own list no longer holds,
        // stays exactly where it was: only a name the node is proven to lack
        // gets dimmed.
        if (name === undefined) { return; }
        $(this).prop('disabled', presentLower.indexOf(String(name).toLowerCase()) === -1);
      });
    });
  });
}

function hypervVLANModeChange(item) {
  var parent = [...document.querySelectorAll('fieldset.compute_attributes')].filter(el => el.contains(item))[0];
  if (parent == undefined) {
    parent = [...document.querySelectorAll('div.fields')].filter(el => el.contains(item))[0];
  }

  $(parent.querySelectorAll('[data-hyperv-vlan-mode]')).hide();
  $(parent.querySelectorAll('[data-hyperv-vlan-mode] input')).attr('disabled', true);
  $(parent.querySelectorAll('[data-hyperv-vlan-mode] select')).attr('disabled', true);

  var id = '[data-hyperv-vlan-mode="' + $(item).val().toLowerCase() + '"]';
  $(parent.querySelectorAll(id)).show();
  $(parent.querySelectorAll(id + ' input')).removeAttr('disabled');
  $(parent.querySelectorAll(id + ' select')).removeAttr('disabled');
}

function hypervVLANPrivateModeChange(item) {
  var parent = [...document.querySelectorAll('fieldset.compute_attributes')].filter(el => el.contains(item))[0];
  if (parent == undefined) {
    parent = [...document.querySelectorAll('div.fields')].filter(el => el.contains(item))[0];
  }

  $(parent.querySelectorAll('[data-hyperv-vlan-private-mode]')).hide();
  $(parent.querySelectorAll('[data-hyperv-vlan-private-mode] input')).attr('disabled', true);

  if ($(item).val() == 'Promiscuous') {
    var id = '[data-hyperv-vlan-private-mode="plural"]';
  } else {
    var id = '[data-hyperv-vlan-private-mode="singular"]';
  }
  $(parent.querySelectorAll(id)).show();
  $(parent.querySelectorAll(id + ' input')).removeAttr('disabled');
}
