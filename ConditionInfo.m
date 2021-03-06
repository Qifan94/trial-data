% ConditionInfo may be optionally bound to a specific set of trial data
% which will be passed to getAttributeValueFn() when requesting the values
% of each attribute for each trial. If not bound to anything, this function will receive
% [] as its first argument, with the assumption being that the function handle in this
% case is already bound to a specific set of trial data.
classdef (ConstructOnLoad) ConditionInfo < ConditionDescriptor

    properties
        % function with signature:
        % valuesByAttribute = getAttributeValueFn(trialData, attributeNames)
        % 
        % - trialData: typically a struct array or TrialData instance
        % - attributeNames: cellstr of attribute names (from the
        %     "requestAs" list)
        % - valuesByAttribute : struct array where v(iTrial).attributeName = attribute value on this trial
        getAttributeValueFn = @ConditionInfo.defaultGetAttributeFn;
        
        % function with signature:
        % nTrials = getNTrialsFn(trialData)
        getNTrialsFn = @ConditionInfo.defaultGetNTrialsFn;
    end
    
    properties(SetAccess=protected)
        % has apply to trial data already been called?
        applied = false;
        
        % T is number of trials
        % A is number of attributes
        values % T x A cell array : values{iTrial, iAttr} = value
        
        % a mask over trials (T x 1). A trial is valid if all of its attribute values are in the
        % value lists for those attributes, AND manualInvalid(i) == 0
        manualInvalid % used by markInvalid
    end
    
    %%% End of properties saved to disk
    
    % Properties which wrap eponymous properties inside odc (on-demand cache)
    properties(Dependent, Transient, SetAccess=protected)
        % which condition does each trial belong to
        conditionIdx % T x 1 array of linear index into conditions for each trials
        
        % T x A matrix of which condition each trial belongs to as a row vector of subscript indices
        conditionSubsIncludingManualInvalid

        % T x A matrix of which condition each trial belongs to as a row
        % vector of subscript indices, except invalid trials will have all
        % NaNs in their row
        conditionSubs 
        
        % nConditions x 1 cell array of idx in each condition
        listByCondition
    end

    properties(Dependent, Transient)
        nTrials
        
        countByCondition
        
        nConditionsNonEmpty
        
        % a mask over trials (T x 1). A trial is valid if all of its attribute values are in the
        % value lists for those attributes, AND manualInvalid(i) == 0
        % logical mask indicating which trials are valid to include when returning groups
        % this mask does not affect any other functions for grabbing attribute values / unique attributes, etc.
        valid  
        
        computedValid

        nValid
    end

    methods % constructor, odc build
        function ci = ConditionInfo()
            ci = ci@ConditionDescriptor();
        end
             
        function odc = buildOdc(ci) %#ok<MANU>
            odc = ConditionInfoOnDemandCache();
        end
    end

    methods % get / set data stored inside odc
        function v = get.conditionIdx(ci)
            v = ci.odc.conditionIdx;            
            if isempty(v)
                ci.odc.conditionIdx = ci.buildConditionIdx();
                v = ci.odc.conditionIdx;
            end
        end
        
        function ci = set.conditionIdx(ci, v)
            ci.odc = ci.odc.copy();
            ci.odc.conditionIdx = v;
        end
        
        function v = get.conditionSubsIncludingManualInvalid(ci)
            v = ci.odc.conditionSubsIncludingManualInvalid;            
            if isempty(v)
                ci.odc.conditionSubsIncludingManualInvalid = ci.buildConditionSubsIncludingManualInvalid();
                v = ci.odc.conditionSubsIncludingManualInvalid;
            end
        end
        
        function ci = set.conditionSubsIncludingManualInvalid(ci, v)
            ci.odc = ci.odc.copy();
            ci.odc.conditionSubsIncludingManualInvalid = v;
        end
        
        function v = get.conditionSubs(ci)
            v = ci.odc.conditionSubs;            
            if isempty(v)
                ci.odc.conditionSubs = ci.buildConditionSubs();
                v = ci.odc.conditionSubs;
            end
        end
        
        function ci = set.conditionSubs(ci, v)
            ci.odc = ci.odc.copy();
            ci.odc.conditionSubs = v;
        end
        
        function v = get.listByCondition(ci)
            v = ci.odc.listByCondition;            
            if isempty(v)
                ci.odc.listByCondition = ci.buildListByCondition();
                v = ci.odc.listByCondition;
            end
        end
        
        function ci = set.listByCondition(ci, v)
            ci.odc = ci.odc.copy();
            ci.odc.listByCondition = v;
        end
    end
        
    methods % Build data stored inside odc
        function conditionIdx = buildConditionIdx(ci)
            if ci.nTrials > 0
                conditionIdx = TensorUtils.subMat2Ind(ci.conditionsSize, ci.conditionSubs);
            else
                conditionIdx = [];
                return;
            end
        end
        
        % compute which condition each trial falls into, without writing
        % NaNs for manualInvalid marked trials
        function subsMat = buildConditionSubsIncludingManualInvalid(ci)
            % filter out any that don't have a valid attribute value
            % along the other non-axis attributes which act as a filter
            % (i.e. have a manual value list as well)
            valueList = ci.buildAttributeFilterValueListStruct();
            matchesFilters = ci.getAttributeMatchesOverTrials(valueList);
            
            if ci.nAxes == 0
                subsMat = onesvec(ci.nTrials);
                assert(ci.nConditions == 1);
                subsMat(~matchesFilters, :) = NaN;
            
            elseif ci.nConditions > 0 && ci.nTrials > 0
                subsMat = nan(ci.nTrials, ci.nAxes);
                for iX = 1:ci.nAxes
                    % accept the first axis value that matches
                    matchMatrix = ci.getAttributeMatchesOverTrials(ci.axisValueLists{iX});
                    [tf, match] = max(matchMatrix, [], 2);
                    subsMat(tf, iX) = match(tf);
                end
                
                % mark as NaN if it doesn't match for every attribute
                subsMat(any(subsMat == 0, 2), :) = NaN;
              
                subsMat(~matchesFilters, :) = NaN;
            else
                subsMat = [];
            end
        end
        
        function valueList = buildAttributeFilterValueListStruct(ci)
            mask = ci.attributeActsAsFilter;
            names = ci.attributeNames(mask);
            vals = ci.attributeValueLists(mask);
            valueList = struct();
            for iA = 1:numel(names)
                valueList.(names{iA}) = vals{iA};
            end
        end
        
        function subsMat = buildConditionSubs(ci)
            subsMat = ci.conditionSubsIncludingManualInvalid;
            subsMat(ci.manualInvalid, :) = NaN;
        end
        
        function list = buildListByCondition(ci)
            list = cell(ci.conditionsSize);
            for iC = 1:ci.nConditions
                list{iC} = makecol(find(ci.conditionIdx == iC));
                if isempty(list{iC})
                    % ensure it can be concatenated into a column
                    % vector using cell2mat
                    list{iC} = nan(0, 1);
                end
            end
        end
        
    end

    methods % ConditionDescriptor overrides and utilities for auto list generation
        function printOneLineDescription(ci)           
            if ci.nAxes == 0
                axisStr = 'no grouping axes';
            else
                axisStr = strjoin(ci.axisDescriptions, ' , ');
            end
            
            attrFilter = ci.attributeNames(ci.attributeActsAsFilter);
            if isempty(attrFilter)
                filterStr = 'no filtering';
            else
                filterStr = sprintf('filtering by %s', strjoin(attrFilter));
            end
            
            validStr = sprintf('(%d valid)', nnz(ci.computedValid));
            
            tcprintf('inline', '{yellow}%s: {none}%s, %s %s\n', ...
                class(ci), axisStr, filterStr, validStr);
        
        end
        
        function ci = freezeAppearances(ci)
            % freeze current appearance information, but only store
            % conditions that have a trial in them now (which can save
            % significant searching time)
            ci.warnIfNoArgOut(nargout);
            if ~ci.applied
                ci = freezeAppearances@ConditionDescriptor(ci);
                return;
            end
            mask = ci.countByCondition > 0;
            ci.frozenAppearanceConditions = ci.conditions(mask);
            ci.frozenAppearanceData = ci.appearances(mask);
            ci.appearanceFn = @ConditionDescriptor.frozenAppearanceFn;
        end
        
        function valueList = buildAttributeValueLists(ci)
            if ~ci.applied
                % act like ConditionDescriptor before applied to trial data
                valueList = buildAttributeValueLists@ConditionDescriptor(ci);
                return;
            end
                
            % figure out the automatic value lists
            modes = ci.attributeValueModes;
            valueList = cellvec(ci.nAttributes);
            for i = 1:ci.nAttributes
                switch modes(i) 
                    case ci.AttributeValueListAuto
                        % compute unique bins
                        valueList{i} = ci.computeAutoListForAttribute(i);
                        
                    case ci.AttributeValueListManual
                        % use manual list
                        valueList{i} = ci.attributeValueListsManual{i};
                        
                    case ci.AttributeValueBinsManual
                        % use specified bins
                        valueList{i} = ci.attributeValueBinsManual{i};
                        
                    case ci.AttributeValueBinsAutoUniform
                        % compute bin boundaries
                        valueList{i} = ci.computeAutoUniformBinsForAttribute(i);
                        
                    case ci.AttributeValueBinsAutoQuantiles
                        % compute bin boundaries
                        valueList{i} = ci.computeAutoQuantileBinsForAttribute(i);
                end
                valueList{i} = makecol(valueList{i});
            end
        end
        
        function valueList = computeAutoListForAttribute(ci, attrIdx)
            vals = ci.getAttributeValues(attrIdx);
            if ci.attributeNumeric(attrIdx)
                valueList = unique(removenan(vals));
                % include NaN in the list if one is found
                if any(isnan(vals))
                    valueList(end+1) = NaN;
                end
            else
                % include empty values in the list if found
%                 emptyMask = cellfun(@isempty, vals);
%                 vals = vals(~emptyMask);
                valueList = unique(vals);
            end
        end             
        
        function bins = computeAutoUniformBinsForAttribute(ci, attrIdx)
            vals = cell2mat(ci.values(:, attrIdx));
            nBins = ci.attributeValueBinsAutoCount(attrIdx);
            minV = nanmin(vals);
            maxV = nanmax(vals);
            
            if isnan(minV) || isnan(maxV) || isnan(nBins)
                bins = [NaN, NaN];
            else
                binEdges = makecol(linspace(minV, maxV, nBins + 1));
                bins = [ binEdges(1:end-1), binEdges(2:end) ];
            end
        end
        
        function bins = computeAutoQuantileBinsForAttribute(ci, attrIdx)
            vals = removenan(cell2mat(ci.values(:, attrIdx)));
            nBins = ci.attributeValueBinsAutoCount(attrIdx);
            
            if isempty(vals);
                bins = [NaN, NaN];
            else
                binEdges = makecol(quantile(vals, linspace(0, 1, nBins+1)));
                bins = [ binEdges(1:end-1), binEdges(2:end) ];
            end
        end
        
        function valueListAsStrings = buildAttributeValueListsAsStrings(ci)
            if ~ci.applied
                % act like ConditionDescriptor before applied to trial data
                valueListAsStrings = buildAttributeValueListsAsStrings@ConditionDescriptor(ci);
                return;
            end
            
            % rely on ConditionDescriptor's implementation, substitute
            % where necessary
            modes = ci.attributeValueModes;
            valueListAsStrings = buildAttributeValueListsAsStrings@ConditionDescriptor(ci);
            valueList = ci.attributeValueLists;
            
            for i = 1:ci.nAttributes
                switch modes(i) 
                    case ci.AttributeValueListAuto
                        % convert populated list to cellstr
                        if ci.attributeNumeric(i)
                            valueListAsStrings{i} = arrayfun(@num2str, valueList{i}, 'UniformOutput', false);
                        else
                            valueListAsStrings{i} = valueList{i};
                        end
                end
                valueListAsStrings{i} = makecol(valueListAsStrings{i});
            end
        end
        
        function valueListByAxes = buildAxisValueLists(ci)
            valueListByAxes = buildAxisValueLists@ConditionDescriptor(ci);
            if ~ci.applied
                return;
            end
            
            for iX = 1:ci.nAxes
                % build a cellstr of descriptions of the values along this axis
               switch ci.axisValueListModes(iX)
                   case ci.AxisValueListAutoOccupied
                       % need to filter by which values are actually
                       % occupied by at least one trial
                       keep = any(ci.getAttributeMatchesOverTrials(valueListByAxes{iX}), 1);
                       valueListByAxes{iX} = makecol(valueListByAxes{iX}(keep));
                end
            end
        end

        function mask = getAttributeMatchesOverTrials(ci, valueStruct)
            % valueStruct is a struct where .attribute = [vals] or {vals} 
            % matches trials where attribute takes a value in vals
            % return a logical mask nTrials x 1 indicating these matches
            % if valueStruct is a length nValues struct vector, mask will
            % be nTrials x nValues
           
            if ci.nTrials == 0
                mask = logical([]);
                return;
            end
            
            nValues = numel(valueStruct);
            mask = true(ci.nTrials, nValues);
            
            fields = fieldnames(valueStruct);
            attrIdx = ci.assertHasAttribute(fields);
            
            for iF = 1:numel(fields) % loop over attributes to match
                attrVals = ci.getAttributeValues(attrIdx(iF));
                switch ci.attributeValueModes(attrIdx(iF))
                    
                    case {ci.AttributeValueListAuto, ci.AttributeValueListManual}
                        % match against value lists
                        for iV = 1:nValues % loop over each value in value list
                            valsThis = valueStruct(iV).(fields{iF});
                            
                            % check whether value list has sublists within
                            % and flatten them if so
                            if ci.attributeNumeric(attrIdx(iF))
                                if iscell(valsThis)
                                    valsThis = [valsThis{:}];
                                    % groups of values per each element
                                end
                            else
                                % non-numeric
                                if ~iscellstr(valsThis) && ~ischar(valsThis)
                                    valsThis = [valsThis{:}];
                                end
                            end
                            
                            mask(:, iV) = mask(:, iV) & ...
                                ismember(attrVals, valsThis);
                        end
                            
                    case {ci.AttributeValueBinsManual, ci.AttributeValueBinsAutoUniform, ...
                            ci.AttributeValueBinsAutoQuantiles}
                        % match against bins. valueStruct.attr is nBins x 2 bin edges
                        for iV = 1:nValues
                            mask(:, iV) = mask(:, iV) & ...
                                matchAgainstBins(attrVals, valueStruct(iV).(fields{iF}));
                        end
                end
            end
            
            function binAccept = matchAgainstBins(vals, bins)
                binAccept = any(bsxfun(@ge, vals, bins(:, 1)') & bsxfun(@le, vals, bins(:, 2)'), 2);
            end
        end
        
        function values = getAttributeValues(ci, name)
            idx = ci.getAttributeIdx(name);
            values = ci.values(:, idx);
            if ci.attributeNumeric(idx)
                values = cell2mat(values);
            end
        end
        
        function ci = maskAttributes(ci, mask)
            ci.warnIfNoArgOut(nargout);
            ci.values = ci.values(:, mask);
            ci = maskAttributes@ConditionDescriptor(ci, mask);
        end
    end

    methods % Trial utilities and dependent properties
        function counts = get.countByCondition(ci)
            counts = cellfun(@length, ci.listByCondition);
        end
        
        function nConditions = get.nConditionsNonEmpty(ci)
            nConditions = nnz(~cellfun(@isempty, ci.listByCondition));
        end

        function nt = get.nTrials(ci)
            nt = size(ci.values, 1);
        end

        % mark additional trials invalid
        function ci = markInvalid(ci, invalid)
            ci.warnIfNoArgOut(nargout);
            ci.manualInvalid(invalid) = true;
            ci = ci.invalidateCache();
        end
        
        % overwrite manualInvalid with invalid, ignoring what was already
        % marked invalid
        function ci = setInvalid(ci, invalid)
            % only invalidate if changing
            ci.warnIfNoArgOut(nargout);
            assert(isvector(invalid) & numel(invalid) == ci.nTrials, 'Size mismatch');
            if any(ci.manualInvalid ~= invalid)
                ci.manualInvalid = makecol(invalid);
                ci = ci.invalidateCache();
            end
        end

        function valid = get.valid(ci)
            % return a mask which takes into account having a valid value for each attribute
            % specified, as well as the markInvalid function which stores its results in .manualInvalid
            valid = ~ci.manualInvalid & ci.computedValid;
        end
        
        function computedValid = get.computedValid(ci)
            if ci.nTrials > 0
                computedValid = all(~isnan(ci.conditionSubsIncludingManualInvalid), 2);
            else
                computedValid = [];
            end
        end

        function nValid = get.nValid(ci)
            nValid = nnz(ci.valid);
        end
        
        function mask = getIsTrialInSomeGroup(ci)
            mask = ~isnan(ci.conditionIdx);
        end
        
        function ci = selectTrials(ci, selector)
            ci.warnIfNoArgOut(nargout);
            
            assert(isvector(selector), 'Selector must be vector of indices or vector mask');
            % cache everything ahead of time because some are dynamically
            % computed from the others
            
            ci.manualInvalid = ci.manualInvalid(selector);
            ci.values = ci.values(selector, :);
            ci = ci.invalidateCache();
        end
    end
    
    methods % Apply to trial data
        function ci = initializeWithNTrials(ci, N)
            ci.warnIfNoArgOut(nargout);
            % build empty arrays for N trials
            ci.manualInvalid = false(N, 1);
            ci.values = cell(N, ci.nAttributes);
        end
        
        function ci = applyToTrialData(ci, td)
            % build the internal attribute value list (and number of trials)
            % from td.
            ci.warnIfNoArgOut(nargout);
            
            % set trialCount to match length(trialData)
            nTrials = ci.getNTrialsFn(td);
            ci = ci.initializeWithNTrials(nTrials);

            if ci.nAttributes > 0 && ci.nTrials > 0
                % fetch valuesByAttribute using callback function
                valueStruct = ci.requestAttributeValues(td, ci.attributeNames);
                valueCell = struct2cell(valueStruct)';
                
                % store in .values cell
                ci.values = valueCell;
                
                ci = ci.fixAttributeValues();
            end
            
            ci.applied = true;
            ci = ci.invalidateCache();
        end
        
        function ci = fixAttributeValues(ci, attrIdx)
            ci.warnIfNoArgOut(nargout);
            if ci.nAttributes == 0 || ci.nTrials == 0
                return;
            end
            
            if nargin < 2
                % go over all attributes if not specified
                attrIdx = 1:ci.nAttributes;
            end
            
            for iList = 1:numel(attrIdx)
                i = attrIdx(iList);
                vals = ci.values(:, i);

                % check for numeric, replace empty with NaN
                emptyMask = cellfun(@isempty, vals);
                vals(emptyMask) = {NaN};
                try
                    mat = cellfun(@double, vals);
                    assert(numel(vals) == numel(mat));
                    ci.values(:, i) = num2cell(mat);
                    ci.attributeNumeric(i) = true;
                catch
                    % replace empty and NaN with '' (NaN for strings)
                    nanMask = cellfun(@(x) any(isnan(x)), vals);
                    vals(nanMask) = {''};
                    
                    % check for cellstr
                    if iscellstr(vals)
                        ci.values(:, i) = vals;
                        ci.attributeNumeric(i) = false;
                    else
                        error('Attribute %s values were neither uniformly scalar nor strings', ci.attributeNames{i});
                    end
                end
            end
        end
        
        function ci = setAttributeValueData(ci, name, dataCell)
            if ~iscell(dataCell)
                dataCell = num2cell(dataCell);
            end
            assert(numel(dataCell) == ci.nTrials, 'Data must be size nTrials');
            
            idx = ci.assertHasAttribute(name);
            ci.values(:, idx) = dataCell;
            
            ci = ci.fixAttributeValues(idx);
            
            ci.invalidateCache();
        end
        
        function assertNotApplied(ci)
            if ci.applied
                error('You must unbind this ConditionInfo before adding attributes');
            end
        end

        function ci = addAttribute(ci, name, varargin)
            ci.warnIfNoArgOut(nargout);
                        
            if ci.applied
                % ensure values are specified if already applied
                % since we won't be requesting them
                p = inputParser;
                p.KeepUnmatched = true;
                p.addParamValue('values', {}, @(x) islogical(x) || isnumeric(x) || iscell(x)); 
                p.parse(varargin{:});
                
                if ismember('values', p.UsingDefaults)
                    error('This ConditionInfo has already been applied to data. values must be specified when adding new attributes');
                end
                
                % add via ConditionDescriptor
                ci = addAttribute@ConditionDescriptor(ci, name, p.Unmatched);
                
                % set the values in my .values cell array
                vals = p.Results.values;
                assert(numel(vals) == ci.nTrials, ...
                    'Values provided for attribute must have numel == nTrials');

                iAttr = ci.nAttributes;
                % critical to update attribute numeric here!
                if iscell(vals)
                    ci.attributeNumeric(iAttr) = false;
                    ci.values(:, iAttr) = vals;
                else
                    ci.attributeNumeric(iAttr) = true;
                    ci.values(:, iAttr) = num2cell(vals);
                end
                
                % fix everything up and rebuild the caches
                ci = ci.fixAttributeValues();
                ci = ci.invalidateCache();
            else
                % if not applied, no need to do anything special
                ci = addAttribute@ConditionDescriptor(ci, name, varargin{:});
            end
        end
        
        function valueStruct = requestAttributeValues(ci, td, attrNames, requestAs)
            % lookup requestAs name if not specified
            if nargin < 4
                requestAs = ci.attributeRequestAs(strcmp(ci.attributeNames, attrNames));
            end
                
            % translate into request as names
            if ci.getNTrialsFn(td) == 0
                valueStruct = struct();
            else
                valueStructRequestAs = ci.getAttributeValueFn(td, requestAs);

                % check the returned size and field names
                assert(numel(valueStructRequestAs) == ci.nTrials, 'Number of elements returned by getAttributeFn must match nTrials');
                assert(all(isfield(valueStructRequestAs, requestAs)), 'Number of elements returned by getAttributeFn must match nTrials');

                % translate back into attribute names
                valueStruct = mvfield(valueStructRequestAs, requestAs, attrNames);
                valueStruct = orderfields(valueStruct, attrNames);
                valueStruct = makecol(valueStruct);
            end
        end
    end

    methods % convert to ConditionDescriptor
        % build a static ConditionDescriptor for the current groupByList
        function cd = getConditionDescriptor(ci, varargin)
            cd = ConditionDescriptor.fromConditionDescriptor(ci);
        end
    end

    methods(Static) % From condition descriptor and default callbacks
        % Building from a condition descriptor with an accessor method
        function ci = fromConditionDescriptor(cd, varargin)
            p = inputParser;
            p.addOptional('trialData', [], @(x) true);
            p.addParamValue('getAttributeFn', @ConditionInfo.defaultGetAttributeFn, @(x) isa(x, 'function_handle'));
            p.addParamValue('getNTrialsFn', @ConditionInfo.defaultGetNTrialsFn, @(x) isa(x, 'function_handle'));
            p.parse(varargin{:});
            
            % build up the condition info
            ci = ConditionInfo();
            ci.getAttributeFn = p.Results.getAttributeFn;
            ci.getNTrialsFn = p.Results.getNTrialsFn;
            
            % Have conditionDescriptor copy over the important details
            ci = ConditionDescriptor.fromConditionDescriptor(cd, ci);
            
            % and then apply to the trialData
            if ~isempty(p.Results.trialData)
                ci.applyToTrialData(p.Results.trialData);
            end
        end
        
        % construct condition descriptor from a struct of attribute values
        function cd = fromStruct(s)
            cd = ConditionInfo();
            cd = cd.addAttributes(fieldnames(s));
            cd = cd.applyToTrialData(s);
        end

        % return a scalar struct with one field for each attribute containing the attribute values
        % as a cell array or numeric vector
        function values = defaultGetAttributeFn(data, attributeNames, varargin)
            assert(isstruct(data) || isa(data, 'TrialData'), 'Please provide getAttributeFn if data is not struct or TrialData');
            
            if isstruct(data)
                % TODO implement request as renaming here
                values = keepfields(data, attributeNames);
%                 for iAttr = 1:length(attributeNames)
%                     attr = attributeNames{iAttr};
%                     valuesByAttribute.(attr) = {data.(attr)};
%                 end
            elseif isa(data, 'TrialData')
                values = keepfields(data.getParamStruct, attributeNames);
            else
                error('Please provide .getAttributeFn to request attributes from this data type');
            end
        end
        
        function nTrials = defaultGetNTrialsFn(data, varargin)
            if isempty(data)
                nTrials = 0;
                return;
            end
            
            assert(isstruct(data) || isa(data, 'TrialData'), 'Please provide getNTrialsFn if data is not struct or TrialData');
            if isstruct(data)
                nTrials = numel(data);
            else
                nTrials = data.nTrials;
            end
        end
        
        % same as ConditionDescriptor, except skips conditions with no
        % trials so that the colors stay maximally separated
        function a = defaultAppearanceFn(ci, varargin)
            % returns a struct specifying the default set of appearance properties 
            % for the given group. indsGroup is a length(ci.groupByList) x 1 array
            % of the inds where this group is located in the high-d array, and dimsGroup
            % gives the full dimensions of the list of groups.
            %
            % We vary color along all axes simultaneously, using the linear
            % inds.
            %
            % Alternatively, if no arguments are passed, simply return a set of defaults

            nConditions = ci.nConditions;
            nConditionsNonEmpty = ci.nConditionsNonEmpty;
            countsByCondition = ci.countByCondition;
            
            a = emptyStructArray(ci.conditionsSize, {'color', 'lineWidth'});

            if nConditionsNonEmpty == 1
                cmap = [0.3 0.3 1];
            else
                cmap = distinguishable_colors(nConditionsNonEmpty);
            end
             
            colorInd = 1;
            for iC = 1:nConditions
                 if countsByCondition(iC) == 0
                     a(iC).lineWidth = 1;
                     a(iC).color = 'k';
                 else
                     a(iC).lineWidth = 2;
                     a(iC).color = cmap(colorInd, :);
                     colorInd = colorInd + 1;
                 end
            end
        end

    end

end
