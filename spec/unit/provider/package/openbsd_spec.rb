#! /usr/bin/env ruby
require 'spec_helper'
require 'stringio'

provider_class = Puppet::Type.type(:package).provider(:openbsd)

describe provider_class do
  subject { provider_class }

  def package(args = {})
    defaults = { :name => 'bash', :provider => 'openbsd' }
    Puppet::Type.type(:package).new(defaults.merge(args))
  end

  def expect_read_from_pkgconf(lines)
    pkgconf = stub(:readlines => lines)
    File.expects(:exist?).with('/etc/pkg.conf').returns(true)
    File.expects(:open).with('/etc/pkg.conf', 'rb').returns(pkgconf)
  end

  before :each do
    # Stub some provider methods to avoid needing the actual software
    # installed, so we can test on whatever platform we want.
    provider_class.stubs(:command).with(:pkginfo).returns('/bin/pkg_info')
    provider_class.stubs(:command).with(:pkgadd).returns('/bin/pkg_add')
    provider_class.stubs(:command).with(:pkgdelete).returns('/bin/pkg_delete')
  end

  context "::instances" do
    it "should return nil if execution failed" do
      subject.expects(:execpipe).raises(Puppet::ExecutionFailure, 'wawawa')
      subject.instances.should be_nil
    end

    it "should return the empty set if no packages are listed" do
      subject.expects(:execpipe).with(%w{/bin/pkg_info -a}).yields(StringIO.new(''))
      subject.instances.should be_empty
    end

    it "should return all packages when invoked" do
      fixture = File.read(my_fixture('pkginfo.list'))
      subject.expects(:execpipe).with(%w{/bin/pkg_info -a}).yields(fixture)
      subject.instances.map(&:name).sort.should ==
        %w{bash bzip2 expat gettext libiconv lzo openvpn python vim wget}.sort
    end
  end

  context "#install" do
    it "should fail if the resource doesn't have a source" do
      provider = subject.new(package())

      File.expects(:exist?).with('/etc/pkg.conf').returns(false)

      expect {
        provider.install
      }.to raise_error Puppet::Error, /must specify a package source/
    end

    it "should fail if /etc/pkg.conf exists, but is not readable" do
      provider = subject.new(package())

      File.expects(:exist?).with('/etc/pkg.conf').returns(true)
      File.expects(:open).with('/etc/pkg.conf', 'rb').raises(Errno::EACCES)

      expect {
        provider.install
      }.to raise_error Errno::EACCES, /Permission denied/
    end

    it "should fail if /etc/pkg.conf exists, but there is no installpath" do
      provider = subject.new(package())

      expect_read_from_pkgconf([])
      expect {
        provider.install
      }.to raise_error Puppet::Error, /No valid installpath found in \/etc\/pkg\.conf and no source was set/
    end

    it "should install correctly when given a directory-unlike source" do
      ENV.should_not be_key 'PKG_PATH'

      source = '/whatever.pkg'
      provider = subject.new(package(:source => source))
      provider.expects(:pkgadd).with do |name|
        ENV.should_not be_key 'PKG_PATH'
        name.should == source
      end

      provider.install
      ENV.should_not be_key 'PKG_PATH'
    end

    it "should install correctly when given a directory-like source" do
      ENV.should_not be_key 'PKG_PATH'

      source = '/whatever/'
      provider = subject.new(package(:source => source))
      provider.expects(:pkgadd).with do |name|
        ENV.should be_key 'PKG_PATH'
        ENV['PKG_PATH'].should == source

        name.should == provider.resource[:name]
      end
      provider.expects(:execpipe).with(%w{/bin/pkg_info -I bash}).yields('')

      provider.install
      ENV.should_not be_key 'PKG_PATH'
    end

    it "should install correctly when given a CDROM installpath" do
      ENV.should_not be_key 'PKG_PATH'

      provider = subject.new(package())

      dir = '/mnt/cdrom/5.2/packages/amd64/'
      expect_read_from_pkgconf(["installpath = #{dir}"])
      provider.expects(:pkgadd).with do |name|
        ENV.should be_key 'PKG_PATH'
        ENV['PKG_PATH'].should == dir

        name.should == provider.resource[:name]
      end

      provider.install
      ENV.should_not be_key 'PKG_PATH'
    end

    it "should install correctly when given a ftp mirror" do
      ENV.should_not be_key 'PKG_PATH'

      provider = subject.new(package())

      url = 'ftp://your.ftp.mirror/pub/OpenBSD/5.2/packages/amd64/'
      expect_read_from_pkgconf(["installpath = #{url}"])
      provider.expects(:pkgadd).with do |name|
        ENV.should be_key 'PKG_PATH'
        ENV['PKG_PATH'].should == url

        name.should == provider.resource[:name]
      end

      provider.install
      ENV.should_not be_key 'PKG_PATH'
    end

    it "should strip leading whitespace in installpath" do
      provider = subject.new(package())

      dir = '/one/'
      lines = ["# Notice the extra spaces after the ='s\n",
               "installpath =   #{dir}\n",
               "# And notice how each line ends with a newline\n"]
      expect_read_from_pkgconf(lines)
      provider.expects(:pkgadd).with do |name|
        ENV.should be_key 'PKG_PATH'
        ENV['PKG_PATH'].should == dir

        name.should == provider.resource[:name]
      end

      provider.install
    end

    it "should not require spaces around the equals" do
      provider = subject.new(package())

      dir = '/one/'
      lines = ["installpath=#{dir}"]
      expect_read_from_pkgconf(lines)
      provider.expects(:pkgadd).with do |name|
        ENV.should be_key 'PKG_PATH'
        ENV['PKG_PATH'].should == dir

        name.should == provider.resource[:name]
      end

      provider.install
    end

    it "should be case-insensitive" do
      provider = subject.new(package())

      dir = '/one/'
      lines = ["INSTALLPATH = #{dir}"]
      expect_read_from_pkgconf(lines)
      provider.expects(:pkgadd).with do |name|
        ENV.should be_key 'PKG_PATH'
        ENV['PKG_PATH'].should == dir

        name.should == provider.resource[:name]
      end

      provider.install
    end

    it "should ignore unknown keywords" do
      provider = subject.new(package())

      dir = '/one/'
      lines = ["foo = bar\n",
               "installpath = #{dir}\n"]
      expect_read_from_pkgconf(lines)
      provider.expects(:pkgadd).with do |name|
        ENV.should be_key 'PKG_PATH'
        ENV['PKG_PATH'].should == dir

        name.should == provider.resource[:name]
      end

      provider.install
    end

    it "should preserve trailing spaces" do
      provider = subject.new(package())

      dir = '/one/   '
      lines = ["installpath = #{dir}"]
      expect_read_from_pkgconf(lines)
      provider.expects(:pkgadd).with do |name|
        ENV.should_not be_key 'PKG_PATH'
        name.should == dir
      end

      provider.install
    end

    %w{ installpath installpath= }.each do |line|
      it "should reject '#{line}'" do
        provider = subject.new(package())

        expect_read_from_pkgconf([line])
        expect {
          provider.install
        }.to raise_error(Puppet::Error, /No valid installpath found in \/etc\/pkg\.conf and no source was set/)
      end
    end
  end

  context "#get_version" do
    it "should return nil if execution fails" do
      provider = subject.new(package)
      provider.expects(:execpipe).raises(Puppet::ExecutionFailure, 'wawawa')
      provider.get_version.should be_nil
    end

    it "should return the package version if in the output" do
      fixture = File.read(my_fixture('pkginfo.list'))
      provider = subject.new(package(:name => 'bash'))
      provider.expects(:execpipe).with(%w{/bin/pkg_info -I bash}).yields(fixture)
      provider.get_version.should == '3.1.17'
    end

    it "should return the empty string if the package is not present" do
      provider = subject.new(package(:name => 'zsh'))
      provider.expects(:execpipe).with(%w{/bin/pkg_info -I zsh}).yields(StringIO.new(''))
      provider.get_version.should == ''
    end
  end

  context "#query" do
    it "should return the installed version if present" do
      fixture = File.read(my_fixture('pkginfo.detail'))
      provider = subject.new(package(:name => 'bash'))
      provider.expects(:pkginfo).with('bash').returns(fixture)
      provider.query.should == { :ensure => '3.1.17' }
    end

    it "should return nothing if not present" do
      provider = subject.new(package(:name => 'zsh'))
      provider.expects(:pkginfo).with('zsh').returns('')
      provider.query.should be_nil
    end
  end
end
