require 'digest'

module Pod

  # The {Lockfile} stores information about the pods that were installed by
  # CocoaPods.
  #
  # It is used in combination with the Podfile to resolve the exact version of
  # the Pods that should be installed (i.e. to prevent `pod install` from
  # upgrading dependencies).
  #
  # Moreover it is used as a manifest of an installation to detect which Pods
  # need to be installed or removed.
  #
  class Lockfile

    # Loads a lockfile form the given path.
    #
    # @note   This method returns nil if the lockfile can't be loaded.
    #
    # @param  [Pathname] path
    #         the path where the lockfile is serialized.
    #
    # @return [Lockfile] a new lockfile.
    #
    def self.from_file(path)
      return nil unless path.exist?
      begin
        hash = YAML.load(File.open(path))
      rescue Exception => e
        raise StandardError, "Podfile.lock syntax error:  #{e.inspect}"
      end
      lockfile = Lockfile.new(hash)
      lockfile.defined_in_file = path
      lockfile
    end

    # Generates a lockfile from a {Podfile} and the list of {Specifications}
    # that were installed.
    #
    # @param  [Podfile] podfile
    #         the podfile that should be used to generate the lockfile.
    #
    # @param  [Array<Specification>] specs
    #         an array containing the podspec that were generated by resolving
    #         the given podfile.
    #
    # @return [Lockfile] a new lockfile.
    #
    def self.generate(podfile, specs)
      Lockfile.new(generate_hash_from_podfile(podfile, specs))
    end

    # @return [String] the file where this Lockfile is defined.
    #
    attr_accessor :defined_in_file

    # @return [String] the hash used to initialize the Lockfile.
    #
    attr_reader :to_hash

    # @param  [Hash] hash
    #         a hash representation of the Lockfile.
    #
    def initialize(hash)
      @to_hash = hash
    end

    # @return [Array<String, Hash{String => Array[String]}>] the pods installed
    #         and their dependencies.
    #
    def pods
      @pods ||= to_hash['PODS'] || []
    end

    # @return [Array<Dependency>] the dependencies of the Podfile used for the
    #         last installation.
    #
    def dependencies
      @dependencies ||= to_hash['DEPENDENCIES'].map { |dep| dependency_from_string(dep) } || []
    end

    # @return [Hash{String => Hash}] a hash where the name of the pods are the
    #         keys and the values are the external source hash the dependency
    #         that required the pod.
    #
    def external_sources
      @external_sources ||= to_hash["EXTERNAL SOURCES"] || {}
    end

    # @return [Array<String>] the names of the installed Pods.
    #
    def pods_names
      @pods_names ||= pods.map do |pod|
        pod = pod.keys.first unless pod.is_a?(String)
        name_and_version_for_pod(pod)[0]
      end
    end

    # @return [Hash{String => Version}] a Hash containing the name of the
    #         installed Pods as the keys and their corresponding {Version} as
    #         the values.
    #
    def pods_versions
      unless @pods_versions
        @pods_versions = {}
        pods.each do |pod|
          pod = pod.keys.first unless pod.is_a?(String)
          name, version = name_and_version_for_pod(pod)
          @pods_versions[name] = version
        end
      end
      @pods_versions
    end

    # @return [Dependency] a dependency that requires the exact version
    #         of a Pod that was installed.
    #
    def dependency_for_installed_pod_named(name)
      version = pods_versions[name]
      raise StandardError, "Attempt to lock a Pod without an known version." unless version
      dependency = Dependency.new(name, version)
      dependency.external_source = external_sources[name]
      dependency
    end

    # @param  [String] The string that describes a {Specification} generated
    #         from {Specification#to_s}.
    #
    # @example Strings examples
    #
    #   "libPusher"
    #   "libPusher (1.0)"
    #   "libPusher (HEAD based on 1.0)"
    #   "RestKit/JSON"
    #
    # @return [String, Version] the name and the version of a
    #         pod.
    #
    def name_and_version_for_pod(string)
      match_data = string.match(/(\S*) \((.*)\)/)
      name = match_data[1]
      vers = Version.from_string(match_data[2])
      [name, vers]
    end

    # @param  [String] The string that describes a {Dependency} generated
    #         from {Dependency#to_s}.
    #
    # @example Strings examples
    #
    #   "libPusher"
    #   "libPusher (= 1.0)"
    #   "libPusher (~> 1.0.1)"
    #   "libPusher (> 1.0, < 2.0)"
    #   "libPusher (HEAD)"
    #   "libPusher (from `www.example.com')"
    #   "libPusher (defined in Podfile)"
    #   "RestKit/JSON"
    #
    # @return [Dependency] the dependency described by the string.
    #
    def dependency_from_string(string)
      match_data = string.match(/(\S*)( (.*))?/)
      name = match_data[1]
      version = match_data[2]
      version = version.gsub(/[()]/,'') if version
      case version
      when nil
        Dependency.new(name)
      when /defined in Podfile/
        # @TODO: inline podspecs are deprecated
        Dependency.new(name)
      when /from `(.*)'/
        external_source_info = external_sources[name]
        Dependency.new(name, external_source_info)
      when /HEAD/
        # @TODO: find a way to serialize from the Downloader the information
        #        necessary to restore a head version.
        Dependency.new(name, :head)
      else
        Dependency.new(name, version)
      end
    end

    # Analyzes the {Lockfile} and detects any changes applied to the {Podfile}
    # since the last installation.
    #
    # For each Pod, it detects one state among the following:
    #
    # - added: Pods that weren't present in the Podfile.
    # - changed: Pods that were present in the Podfile but changed:
    #   - Pods whose version is not compatible anymore with Podfile,
    #   - Pods that changed their head or external options.
    # - removed: Pods that were removed form the Podfile.
    # - unchanged: Pods that are still compatible with Podfile.
    #
    # @param  [Podfile] podfile
    #         the podfile that should be analyzed.
    #
    # @return [Hash{Symbol=>Array[Strings]}] a hash where pods are grouped
    #         by the state in which they are.
    #
    def detect_changes_with_podfile(podfile)
      previous_podfile_deps = dependencies.map(&:name)
      user_installed_pods   = pods_names.reject { |name| !previous_podfile_deps.include?(name) }
      deps_to_install       = podfile.dependencies.dup

      result = {}
      result[:added]      = []
      result[:changed]    = []
      result[:removed]    = []
      result[:unchanged]  = []

      user_installed_pods.each do |pod_name|
        dependency = deps_to_install.find { |d| d.name == pod_name }
        deps_to_install.delete(dependency)
        version = pods_versions[pod_name]
        external_source = external_sources[pod_name]

        if dependency.nil?
          result[:removed] << pod_name
        elsif !dependency.match_version?(version) || dependency.external_source != external_source
          result[:changed] << pod_name
        else
          result[:unchanged] << pod_name
        end
      end

      deps_to_install.each do |dependency|
        result[:added] << dependency.name
      end
      result
    end

    # Writes the Lockfile to a given path.
    #
    # @param  [Pathname] path
    #         the path where the lockfile should be saved.
    #
    # @return [void]
    #
    def write_to_disk(path)
      path.dirname.mkpath unless path.dirname.exist?
      File.open(path, 'w') {|f| f.write(to_yaml) }
      defined_in_file = path
    end

    # @return [String] a string useful to represent the Lockfile in a message
    #         presented to the user.
    #
    def to_s
      "Podfile.lock"
    end

    # @return [String] the YAML representation of the Lockfile, used for
    #         serialization.
    #
    def to_yaml
      to_hash.to_yaml.gsub(/^--- ?\n/,"").gsub(/^([A-Z])/,"\n\\1")
    end

    # Generates a hash representation of the Lockfile generated from a given
    # Podfile and the list of resolved Specifications. This representation is
    # suitable for serialization.
    #
    # @param  [Podfile] podfile
    #         the podfile that should be used to generate the lockfile.
    #
    # @param  [Array<Specification>] specs
    #         an array containing the podspec that were generated by resolving
    #         the given podfile.
    #
    # @return [Hash] a hash representing the Lockfile.
    #
    def self.generate_hash_from_podfile(podfile, specs)
      hash = {}

      # Get list of [name, dependencies] pairs.
      pod_and_deps = specs.map do |spec|
        [spec.to_s, spec.dependencies.map(&:to_s).sort]
      end.uniq

      # Merge dependencies of iOS and OS X version of the same pod.
      tmp = {}
      pod_and_deps.each do |name, deps|
        if tmp[name]
          tmp[name].concat(deps).uniq!
        else
          tmp[name] = deps
        end
      end
      pod_and_deps = tmp.sort_by(&:first).map do |name, deps|
        deps.empty? ? name : { name => deps }
      end
      hash["PODS"] = pod_and_deps

      hash["DEPENDENCIES"] = podfile.dependencies.map{ |d| d.to_s }.sort

      external_sources = {}
      deps = podfile.dependencies.select(&:external?).sort{ |d, other| d.name <=> other.name}
      deps.each{ |d| external_sources[d.name] = d.external_source }
      hash["EXTERNAL SOURCES"] = external_sources unless external_sources.empty?

      checksums = {}
      specs.select { |spec| !spec.defined_in_file.nil? }.each do |spec|
        checksum = Digest::SHA1.hexdigest(File.read(spec.defined_in_file))
        checksum = checksum.encode('UTF-8') if checksum.respond_to?(:encode)
        checksums[spec.name] = checksum
      end
      hash["SPEC CHECKSUMS"] = checksums unless checksums.empty?
      hash["COCOAPODS"] = CORE_VERSION
      hash
    end
  end
end

