# -------------------------------------------------------------------------- #
# Copyright 2002-2019, OpenNebula Project, OpenNebula Systems                #
#                                                                            #
# Licensed under the Apache License, Version 2.0 (the "License"); you may    #
# not use this file except in compliance with the License. You may obtain    #
# a copy of the License at                                                   #
#                                                                            #
# http://www.apache.org/licenses/LICENSE-2.0                                 #
#                                                                            #
# Unless required by applicable law or agreed to in writing, software        #
# distributed under the License is distributed on an "AS IS" BASIS,          #
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.   #
# See the License for the specific language governing permissions and        #
# limitations under the License.                                             #
#--------------------------------------------------------------------------- #
module NSXDriver

    # Class Logical Switch
    class NSXTdfw < NSXDriver::DistributedFirewall

        # ATTRIBUTES
        attr_reader :one_section_id

        # CONSTRUCTOR
        # Creates OpenNebula section if not exists
        def initialize(nsx_client)
            super(nsx_client)
            # Construct base URLs
            @base_url = NSXDriver::NSXConstants::NSXT_DFW_BASE
            @url_sections = @base_url + \
                            NSXDriver::NSXConstants::NSXT_DFW_SECTIONS
            @one_section_id = init_section
        end

        # Sections
        # Creates OpenNebula section if not exists and returns
        # its section_id. Returns its section_id if OpenNebula
        # section already exists
        def init_section
            one_section = section_by_name(
                NSXDriver::NSXConstants::ONE_SECTION_NAME
            )
            one_section ||= create_section(
                NSXDriver::NSXConstants::ONE_SECTION_NAME
            )
            @one_section_id = one_section['id'] if one_section
        end

        # Get all sections
        # Params:
        # - None
        # Return
        # - nil | sections
        def sections
            result = @nsx_client.get(@url_sections)
            return unless result

            result['results']
        end

        # Get section by id
        # Params:
        # - section_id: [String] ID of the section or @one_section_id
        # Return
        # - nil | section
        def section_by_id(section_id = @one_section_id)
            url = @url_sections + '/' + section_id
            result = @nsx_client.get(url)
            result
        end

        # Get section by name
        # Params:
        # - section_name: Name of the section
        # Return
        # - nil | section
        def section_by_name(section_name)
            result = nil
            all_sections = sections
            return result unless all_sections

            all_sections.each do |section|
                result = section if section['display_name'] == section_name
            end
            result
        end

        # Create new section and return the section
        def create_section(section_name)
            section_spec = %(
              {
                  "display_name": "#{section_name}",
                  "section_type": "LAYER3",
                  "stateful": true
              }
            )
            begin
                section_id = @nsx_client.post(@url_sections, section_spec)
            rescue StandardError => e
                raise NSXDriver::DFWError::CreateError, \
                      "Error creating section in NSX: #{e.message}"
            end
            result = section_by_id(section_id)
            raise 'Section was not created in DFW' unless result

            result
        end

        # Delete section
        # Params:
        # - section_id: [String] ID of the section or @one_section_id
        def delete_section(section_id = @one_section_id)
            url = @url_sections + '/' + section_id
            @nsx_client.delete(url)
        end

        # Rules
        # Get all rules of a Section, OpenNebula section if it's not defined
        def rules(section_id = @one_section_id)
            url = @url_sections + '/' + section_id + '/rules'
            result = @nsx_client.get(url)
            result
        end

        # Get rule by id
        def rules_by_id(rule_id)
            url = @base_url + '/rules/' + rule_id
            result = @nsx_client.get(url)
            result
        end

        # Get rule by name
        def rules_by_name(rule_name, section_id = @one_section_id)
            result = nil
            return result unless section_id

            all_rules = rules(section_id)
            return result unless all_rules

            all_rules['results'].each do |rule|
                result = rule if rule['display_name'] == rule_name
            end
            result
        end

        # Create new rule
        def create_rule(rule_spec, section_id = @one_section_id)
            # Get revision from section
            section = section_by_id(section_id)
            unless section
                error_msg = "Section with id #{section_id} not found"
                error = NSXDriver::NSXError::ObjectNotFound
                        .new(error_msg)
                raise error
            end
            revision_id = section['_revision']
            rule_spec['_revision'] = revision_id
            rule_spec = rule_spec.to_json
            url = @url_sections + '/' + section_id + '/rules'
            result = @nsx_client.post(url, rule_spec)
            raise 'Error creating DFW rule' unless result
        end

        # Update rule
        def update_rule(rule_id, rule_spec, section_id = @one_section_id)
            url = @url_sections + '/' + section_id + '/rules/' + rule_id
            rule = rules_by_id(rule_id)
            raise "Rule id #{rule_id} not found" unless rule

            rule_spec['_revision'] = rule['_revision']
            rule_spec = rule_spec.to_json
            result = @nsx_client.put(url, rule_spec)
            raise 'Error updating DFW rule' unless result
        end

        # Delete rule
        def delete_rule(rule_id, section_id = @one_section_id)
            url = @url_sections + '/' + section_id + '/rules/' + rule_id
            # Delete receive a 200 OK also if the rule doesn't exist
            @nsx_client.delete(url)
            result = rules_by_id(rule_id)
            raise 'Error deleting rule in DFW' if result
        end

        # Remove OpenNebula created fw rules for an instance (given a template)
        def clear_opennebula_rules(template)
            template_xml = Nokogiri::XML(template)

            # OpenNebula Instance IDs
            vm_id = template_xml.xpath('//VM/ID').text
            vm_deploy_id = template_xml.xpath('//DEPLOY_ID').text

            # Clean rules
            nics = template_xml.xpath('//TEMPLATE/NIC')
            nics.each do |nic|
                network_id = nic.xpath('NETWORK_ID').text
                sec_groups = nic.xpath('SECURITY_GROUPS').text.split(',')
                sec_groups.each do |sec_group|
                    sg_rules_array = []
                    sg_rules = template_xml.xpath("//SECURITY_GROUP_RULE[SECURITY_GROUP_ID=#{sec_group}]")
                    sg_rules.each do |sg_rule|
                        sg_id = sg_rule.xpath('SECURITY_GROUP_ID').text
                        sg_name = sg_rule.xpath('SECURITY_GROUP_NAME').text
                        rule_name = "#{sg_id} - #{sg_name} - #{vm_id} - #{vm_deploy_id} - #{network_id}"
                        rule = rules_by_name(rule_name, @one_section_id)
                        delete_rule(rule['id'], @one_section_id) if rule
                    end
                end
            end

            # # Clean rules
            # sg_rules = template_xml.xpath('//TEMPLATE/SECURITY_GROUP_RULE')
            # sg_rules.each do |sg_rule|
            #     sg_id = sg_rule.xpath('SECURITY_GROUP_ID').text
            #     sg_name = sg_rule.xpath('SECURITY_GROUP_NAME').text

            #     rule_name = "#{sg_id} - #{sg_name} - #{vm_id} - #{vm_deploy_id}"
            #     rule = rules_by_name(rule_name, @one_section_id)
            #     delete_rule(rule['id'], @one_section_id) if rule
            # end
        end
    end

end