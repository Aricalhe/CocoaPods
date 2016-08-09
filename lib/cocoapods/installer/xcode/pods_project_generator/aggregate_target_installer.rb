module Pod
  class Installer
    class Xcode
      class PodsProjectGenerator
        # Creates the targets which aggregate the Pods libraries in the Pods
        # project and the relative support files.
        #
        class AggregateTargetInstaller < TargetInstaller
          # Creates the target in the Pods project and the relative support files.
          #
          # @return [void]
          #
          def install!
            UI.message "- Installing target `#{target.name}` #{target.platform}" do
              add_target
              create_support_files_dir
              create_support_files_group
              create_xcconfig_file
              if target.requires_frameworks?
                create_info_plist_file
                create_module_map
                create_umbrella_header
              end
              # Because embedded targets live in their host target, CocoaPods
              # copies all of the embedded target's pod_targets to its host
              # targets. Having this script for the embedded target would
              # cause an App Store rejection because frameworks cannot be
              # embedded in embedded targets.
              #
              create_embed_frameworks_script unless target.requires_host_target?
              create_bridge_support_file
              create_copy_resources_script
              create_acknowledgements
              create_dummy_source
            end
          end

          #-----------------------------------------------------------------------#

          private

          # @return [TargetDefinition] the target definition of the library.
          #
          def target_definition
            target.target_definition
          end

          # Ensure that vendored static frameworks and libraries are not linked
          # twice to the aggregate target, which shares the xcconfig of the user
          # target.
          #
          def custom_build_settings
            settings = {
              'CODE_SIGN_IDENTITY[sdk=appletvos*]' => '',
              'CODE_SIGN_IDENTITY[sdk=iphoneos*]'  => '',
              'CODE_SIGN_IDENTITY[sdk=watchos*]'   => '',
              'MACH_O_TYPE'                        => 'staticlib',
              'OTHER_LDFLAGS'                      => '',
              'OTHER_LIBTOOLFLAGS'                 => '',
              'PODS_ROOT'                          => '$(SRCROOT)',
              'PRODUCT_BUNDLE_IDENTIFIER'          => 'org.cocoapods.${PRODUCT_NAME:rfc1034identifier}',
              'SKIP_INSTALL'                       => 'YES',
            }
            super.merge(settings)
          end

          # Creates the group that holds the references to the support files
          # generated by this installer.
          #
          # @return [void]
          #
          def create_support_files_group
            parent = project.support_files_group
            name = target.name
            dir = target.support_files_dir
            @support_files_group = parent.new_group(name, dir)
          end

          # Generates the contents of the xcconfig file and saves it to disk.
          #
          # @return [void]
          #
          def create_xcconfig_file
            native_target.build_configurations.each do |configuration|
              path = target.xcconfig_path(configuration.name)
              gen = Generator::XCConfig::AggregateXCConfig.new(target, configuration.name)
              gen.save_as(path)
              target.xcconfigs[configuration.name] = gen.xcconfig
              xcconfig_file_ref = add_file_to_support_group(path)
              configuration.base_configuration_reference = xcconfig_file_ref
            end
          end

          # Generates the bridge support metadata if requested by the {Podfile}.
          #
          # @note   The bridge support metadata is added to the resources of the
          #         target because it is needed for environments interpreted at
          #         runtime.
          #
          # @return [void]
          #
          def create_bridge_support_file
            if target.podfile.generate_bridge_support?
              path = target.bridge_support_path
              headers = native_target.headers_build_phase.files.map { |bf| sandbox.root + bf.file_ref.path }
              generator = Generator::BridgeSupport.new(headers)
              generator.save_as(path)
              add_file_to_support_group(path)
              @bridge_support_file = path.relative_path_from(sandbox.root)
            end
          end

          # Uniqued Resources grouped by config
          #
          # @return [Hash{ Symbol => Array<Pathname> }]
          #
          def resources_by_config
            library_targets = target.pod_targets.reject do |pod_target|
              pod_target.should_build? && pod_target.requires_frameworks?
            end
            target.user_build_configurations.keys.each_with_object({}) do |config, resources_by_config|
              resources_by_config[config] = library_targets.flat_map do |library_target|
                next [] unless library_target.include_in_build_config?(target_definition, config)
                resource_paths = library_target.file_accessors.flat_map do |accessor|
                  accessor.resources.flat_map { |res| res.relative_path_from(project.path.dirname) }
                end
                resource_bundles = library_target.file_accessors.flat_map do |accessor|
                  accessor.resource_bundles.keys.map { |name| "#{library_target.configuration_build_dir}/#{name.shellescape}.bundle" }
                end
                (resource_paths + resource_bundles + [bridge_support_file].compact).uniq
              end
            end
          end

          # Creates a script that copies the resources to the bundle of the client
          # target.
          #
          # @note   The bridge support file needs to be created before the prefix
          #         header, otherwise it will not be added to the resources script.
          #
          # @return [void]
          #
          def create_copy_resources_script
            path = target.copy_resources_script_path
            generator = Generator::CopyResourcesScript.new(resources_by_config, target.platform)
            generator.save_as(path)
            add_file_to_support_group(path)
          end

          # Creates a script that embeds the frameworks to the bundle of the client
          # target.
          #
          # @note   We can't use Xcode default copy bundle resource phase, because
          #         we need to ensure that we only copy the resources, which are
          #         relevant for the current build configuration.
          #
          # @return [void]
          #
          def create_embed_frameworks_script
            path = target.embed_frameworks_script_path
            frameworks_by_config = {}
            target.user_build_configurations.keys.each do |config|
              relevant_pod_targets = target.pod_targets.select do |pod_target|
                pod_target.include_in_build_config?(target_definition, config)
              end
              frameworks_by_config[config] = relevant_pod_targets.flat_map do |pod_target|
                frameworks = pod_target.file_accessors.flat_map(&:vendored_dynamic_artifacts).map { |fw| "${PODS_ROOT}/#{fw.relative_path_from(sandbox.root)}" }
                frameworks << pod_target.build_product_path('$BUILT_PRODUCTS_DIR') if pod_target.should_build? && pod_target.requires_frameworks?
                frameworks
              end
            end
            generator = Generator::EmbedFrameworksScript.new(frameworks_by_config)
            generator.save_as(path)
            add_file_to_support_group(path)
          end

          # Generates the acknowledgement files (markdown and plist) for the target.
          #
          # @return [void]
          #
          def create_acknowledgements
            basepath = target.acknowledgements_basepath
            Generator::Acknowledgements.generators.each do |generator_class|
              path = generator_class.path_from_basepath(basepath)
              file_accessors = target.pod_targets.map(&:file_accessors).flatten
              generator = generator_class.new(file_accessors)
              generator.save_as(path)
              add_file_to_support_group(path)
            end
          end

          # @return [Pathname] the path of the bridge support file relative to the
          #         sandbox.
          #
          # @return [Nil] if no bridge support file was generated.
          #
          attr_reader :bridge_support_file

          #-----------------------------------------------------------------------#
        end
      end
    end
  end
end