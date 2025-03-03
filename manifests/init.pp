class jupyterhub (
  Stdlib::Absolutepath $prefix = '/opt/jupyterhub',
  Stdlib::Absolutepath $slurm_home = '/opt/software/slurm',
  String $bind_url = 'https://127.0.0.1:8000',
  Boolean $allow_named_servers = true,
  Integer $named_server_limit_per_user = 0,
  Boolean $enable_otp_auth = true,
  Integer $idle_timeout = 0,
  Optional[Array[String]] $admin_groups = [],
  Optional[Array[String]] $blocked_users = ['root', 'toor', 'admin', 'centos', 'slurm'],
  Optional[Hash] $jupyterhub_config_hash = {},
  Optional[Array[String]] $slurm_partitions = [],
) {

  class { 'jupyterhub::base':
    prefix => $prefix
  }

  user { 'jupyterhub':
    ensure  => 'present',
    groups  => 'jupyterhub',
    comment => 'JupyterHub',
    home    => '/run/jupyterhub',
    shell   => '/sbin/nologin',
    system  => true
  }
  group { 'jupyterhub':
    ensure => 'present'
  }

  package { 'configurable-http-proxy':
    ensure   => 'installed',
    provider => 'npm'
  }

  file { 'jupyterhub.service':
    ensure => 'present',
    path   => '/lib/systemd/system/jupyterhub.service',
    source => 'puppet:///modules/jupyterhub/jupyterhub.service'
  }

  file { '/etc/sudoers.d/99-jupyterhub-user':
    ensure  => 'present',
    content => epp('jupyterhub/99-jupyterhub-user', {
      'blocked_users' => $blocked_users,
      'hostname'      => $facts['hostname'],
      'slurm_home'    => $slurm_home,
    })
  }

  file { 'jupyterhub-auth':
    ensure => 'present',
    path   => '/etc/pam.d/jupyterhub-auth',
    source => 'puppet:///modules/jupyterhub/jupyterhub-auth',
    mode   => '0644'
  }

  file { 'jupyterhub-login':
    ensure  => 'present',
    path    => '/etc/pam.d/jupyterhub-login',
    source  => 'puppet:///modules/jupyterhub/jupyterhub-login',
    mode    => '0644',
    require => File['jupyterhub-auth']
  }

  file { ['/etc/jupyterhub', '/etc/jupyterhub/ssl', '/etc/jupyterhub/templates']:
    ensure => directory
  }

  file { '/run/jupyterhub':
    ensure => directory,
    owner  => 'jupyterhub',
    group  => 'jupyterhub',
    mode   => '0755'
  }

  file { '/usr/lib/tmpfiles.d/jupyterhub.conf':
    ensure => 'present',
    source => 'puppet:///modules/jupyterhub/jupyterhub.conf',
    mode   => '0644',
  }

  $slurmformspawner_version = lookup('jupyterhub::slurmformspawner::version')
  $pammfauthenticator_url = lookup('jupyterhub::pammfauthenticator::url')

  $node_prefix = lookup('jupyterhub::node::prefix', String, undef, $prefix)
  $jupyterhub_config_base = parsejson(file('jupyterhub/jupyterhub_config.json'))
  $jupyterhub_config_params = {
    'JupyterHub' => {
      'bind_url'                    => $bind_url,
      'allow_named_servers'         => $allow_named_servers,
      'named_server_limit_per_user' => $named_server_limit_per_user,
      'authenticator_class'         => $enable_otp_auth ? { true => 'pammfauthenticator', false => 'pam' },
      'admin_access'                => Boolean(size($admin_groups) > 0),
      'services'                    => Boolean($idle_timeout > 0) ? {
        true => [{
          'name'    => 'cull-idle',
          'admin'   => true,
          'command' => [
            "${prefix}/bin/python3",
            "${prefix}/bin/cull_idle_servers.py",
            "--timeout=${idle_timeout}"
          ],
        }],
        false => [],
      }
    },
    'Authenticator' => {
      'blocked_users' => $blocked_users,
    },
    'PAMAuthenticator' => {
      'admin_groups' => $admin_groups,
    },
    'SlurmFormSpawner' => {
      'batchspawner_singleuser_cmd' => "${node_prefix}/bin/batchspawner-singleuser",
      'cmd'                         => "${node_prefix}/bin/jupyterhub-singleuser",
      'slurm_bin_path'              => "${slurm_home}/bin",
    }
  }
  $jupyterhub_config = deep_merge($jupyterhub_config_base, $jupyterhub_config_params, $jupyterhub_config_hash)
  file { 'jupyterhub_config.json':
    ensure  => 'present',
    path    => '/etc/jupyterhub/jupyterhub_config.json',
    content => to_json_pretty($jupyterhub_config, true),
    mode    => '0644',
  }

  $kernel_setup = lookup('jupyterhub::kernel::setup', Enum['venv', 'module'], undef, 'venv')
  $module_list = lookup('jupyterhub::kernel::module::list', Array[String], undef, [])
  $venv_prefix = lookup('jupyterhub::kernel::venv::prefix', String, undef, '/opt/ipython-kernel')
  file { 'submit.sh':
    ensure  => 'present',
    path    => '/etc/jupyterhub/submit.sh',
    content => epp('jupyterhub/submit.sh', {
      'kernel_setup'     => $kernel_setup,
      'module_list'      => join($module_list, ' '),
      'node_prefix'      => $node_prefix,
      'venv_prefix'      => $venv_prefix,
      'slurm_partitions' => join($slurm_partitions, ','),
    }),
    mode    => '0644'
  }

  # JupyterHub virtual environment
  exec { 'pip_slurmformspawner':
    command => "${prefix}/bin/pip install --no-cache-dir slurmformspawner==${slurmformspawner_version}",
    creates => "${prefix}/lib/python3.6/site-packages/slurmformspawner-${slurmformspawner_version}.dist-info/",
    require => Exec['pip_batchspawner']
  }

  exec { 'pip_pamela':
    command => "${prefix}/bin/pip install --no-cache-dir https://github.com/minrk/pamela/archive/master.zip",
    creates => "${prefix}/lib/python3.6/site-packages/pamela-1.0.1.dev0-py3.6.egg-info/",
    require => Exec['pip_jupyterhub']
  }

  exec { 'pip_pammfauthenticator':
    command => "${prefix}/bin/pip install --no-cache-dir ${pammfauthenticator_url}",
    creates => "${prefix}/lib/python3.6/site-packages/pammfauthenticator/",
    require => [Exec['pip_jupyterhub'], Exec['pip_pamela']]
  }

  exec {'create_self_signed_sslcert':
    command => "openssl req -newkey rsa:4096 -nodes -keyout key.pem -x509 -days 3650 -out cert.pem -subj '/CN=${::fqdn}'",
    cwd     => '/etc/jupyterhub/ssl',
    creates => ['/etc/jupyterhub/ssl/key.pem', '/etc/jupyterhub/ssl/cert.pem'],
    path    => ['/usr/bin', '/usr/sbin'],
    umask   => '037'
  }

  file { '/etc/jupyterhub/ssl/cert.pem':
    mode    => '0644',
    require => [Exec['create_self_signed_sslcert']]
  }

  file { '/etc/jupyterhub/ssl/key.pem':
    mode    => '0640',
    group   => 'jupyterhub',
    require => [Exec['create_self_signed_sslcert']]
  }

  $pycurl_package_name = lookup('jupyterhub::pycurl::package_name')
  ensure_packages ($pycurl_package_name)

  file { "${prefix}/bin/cull_idle_servers.py":
    source  => 'puppet:///modules/jupyterhub/cull_idle_servers.py',
    mode    => '0755',
    require => Exec['jupyterhub_venv']
  }

  service { 'jupyterhub':
    ensure    => running,
    enable    => true,
    require   => [
      Package[$pycurl_package_name],
      File['submit.sh'],
    ],
    subscribe => [
      Service['sssd'],
      Exec['pip_jupyterhub'],
      Exec['pip_batchspawner'],
      Exec['pip_slurmformspawner'],
      Exec['pip_pammfauthenticator'],
      File['jupyterhub-login'],
      File['jupyterhub.service'],
      File['jupyterhub_config.json'],
      File['/etc/jupyterhub/ssl/cert.pem'],
      File['/etc/jupyterhub/ssl/key.pem'],
      File["${prefix}/bin/cull_idle_servers.py"],
    ],
  }
}
