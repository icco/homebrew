#!/System/Library/Frameworks/Ruby.framework/Versions/1.8/usr/bin/ruby -W0

# This script is called by formula_installer as a separate instance.
# Rationale: Formula can use __END__, Formula can change ENV
# Thrown exceptions are propogated back to the parent process over a pipe

STD_TRAP = trap("INT") { exit! 130 } # no backtrace thanks

at_exit do
  # the whole of everything must be run in at_exit because the formula has to
  # be the run script as __END__ must work for *that* formula.
  main
end

require 'global'
require 'debrew' if ARGV.debug?

def main
  # The main Homebrew process expects to eventually see EOF on the error
  # pipe in FormulaInstaller#build. However, if any child process fails to
  # terminate (i.e, fails to close the descriptor), this won't happen, and
  # the installer will hang. Set close-on-exec to prevent this.
  # Whether it is *wise* to launch daemons from formulae is a separate
  # question altogether.
  if ENV['HOMEBREW_ERROR_PIPE']
    require 'fcntl'
    error_pipe = IO.new(ENV['HOMEBREW_ERROR_PIPE'].to_i, 'w')
    error_pipe.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC)
  end

  raise $! if $! # an exception was already thrown when parsing the formula

  trap("INT", STD_TRAP) # restore default CTRL-C handler

  require 'hardware'
  require 'keg'

  # Force any future invocations of sudo to require the user's password to be
  # re-entered. This is in-case any build script call sudo. Certainly this is
  # can be inconvenient for the user. But we need to be safe.
  system "/usr/bin/sudo", "-k"

  install(Formula.factory($0))
rescue Exception => e
  unless error_pipe.nil?
    e.continuation = nil if ARGV.debug?
    Marshal.dump(e, error_pipe)
    error_pipe.close
    exit! 1
  else
    onoe e
    puts e.backtrace
    exit! 2
  end
end

def post_superenv_hacks f
  # Only allow Homebrew-approved directories into the PATH, unless
  # a formula opts-in to allowing the user's path.
  if f.env.userpaths? or f.recursive_requirements.any? { |rq| rq.env.userpaths? }
    ENV.userpaths!
  end
end

def pre_superenv_hacks f
  # Allow a formula to opt-in to the std environment.
  ARGV.unshift '--env=std' if (f.env.std? or
    f.recursive_dependencies.detect{|d| d.name == 'scons' }) and
    not ARGV.include? '--env=super'
end

def expand_deps f
  f.recursive_dependencies do |dependent, dep|
    if dep.optional? || dep.recommended?
      Dependency.prune unless dependent.build.with?(dep.name)
    elsif dep.build?
      Dependency.prune unless dependent == f
    end
  end.map(&:to_formula)
end

def install f
  deps = expand_deps(f)
  keg_only_deps = deps.select(&:keg_only?)

  pre_superenv_hacks(f)
  require 'superenv'

  deps.each do |dep|
    opt = HOMEBREW_PREFIX/:opt/dep
    fixopt(dep) unless opt.directory? or ARGV.ignore_deps?
  end

  if superenv?
    ENV.keg_only_deps = keg_only_deps.map(&:to_s)
    ENV.deps = deps.map(&:to_s)
    ENV.x11 = f.recursive_requirements.detect { |rq| rq.kind_of?(X11Dependency) }
    ENV.setup_build_environment
    post_superenv_hacks(f)
    f.recursive_requirements.each(&:modify_build_environment)
  else
    ENV.setup_build_environment
    f.recursive_requirements.each(&:modify_build_environment)

    keg_only_deps.each do |dep|
      opt = dep.opt_prefix
      ENV.prepend_path 'PATH', "#{opt}/bin"
      ENV.prepend_path 'PKG_CONFIG_PATH', "#{opt}/lib/pkgconfig"
      ENV.prepend_path 'PKG_CONFIG_PATH', "#{opt}/share/pkgconfig"
      ENV.prepend_path 'ACLOCAL_PATH', "#{opt}/share/aclocal"
      ENV.prepend_path 'CMAKE_PREFIX_PATH', opt
      ENV.prepend 'LDFLAGS', "-L#{opt}/lib" if (opt/:lib).directory?
      ENV.prepend 'CPPFLAGS', "-I#{opt}/include" if (opt/:include).directory?
    end
  end

  if f.fails_with? ENV.compiler
    ENV.send CompilerSelector.new(f, ENV.compiler).compiler
  end

  f.brew do
    if ARGV.flag? '--git'
      system "git init"
      system "git add -A"
    end
    if ARGV.flag? '--interactive'
      ohai "Entering interactive mode"
      puts "Type `exit' to return and finalize the installation"
      puts "Install to this prefix: #{f.prefix}"

      if ARGV.flag? '--git'
        puts "This directory is now a git repo. Make your changes and then use:"
        puts "  git diff | pbcopy"
        puts "to copy the diff to the clipboard."
      end

      interactive_shell f
    else
      f.prefix.mkpath

      begin
        f.install
      rescue Exception => e
        if ARGV.debug?
          debrew e, f
        else
          raise e
        end
      end

      # Find and link metafiles
      f.prefix.install_metafiles Pathname.pwd
    end
  end
end

def fixopt f
  path = if f.linked_keg.directory? and f.linked_keg.symlink?
    f.linked_keg.realpath
  elsif f.prefix.directory?
    f.prefix
  elsif (kids = f.rack.children).size == 1 and kids.first.directory?
    kids.first
  else
    raise
  end
  Keg.new(path).optlink
rescue StandardError
  raise "#{f.opt_prefix} not present or broken\nPlease reinstall #{f}. Sorry :("
end
