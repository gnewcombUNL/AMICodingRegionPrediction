%PREDICTCODINGCROSSSPECIES For each taxonomic ID in 'TaxonomicIDList.csv':
% 1. [If Necessary] Download genomes from NCBI
% 2. [If Necessary] Compile coding and noncoding parent sequences
% 3. Generate AMI profiles for a random selection of training sequences 
%    drawn from the coding and noncoding parent sequences
% 4. Train an SVM on the profiles in the training set
% 5. Use that SVM to predict whether test sequences drawn from each of the 
%    other species is coding or noncoding
% 6. Output prediction metrics to output file (XLSX) 


%% Input Parameters
seqLength = 1000;
setSize = 2000;
minK = 1;
maxK = 16;
forceDownload = false;
taxIdFile = 'TaxonomicIDList.csv';
outputFile = 'CodingRegion_CrossSpecies.xlsx';


% Get Data (if necessary)
genomeFolder = 'NCBIGenomes';
speciesListFile = 'SpeciesList.csv';

if (~isfile(taxIdFile))
    error(['A list of taxonomic IDs must exist in file ', taxIdFile]);
end
    
idList = readtable('TaxonomicIDList.csv');
if (length(idList.Properties.VariableNames) > 1 || ~strcmp(idList.Properties.VariableNames, 'taxaID'))
    error(['A list of taxonomic IDs must exist in file ', taxIdFile, 'with header "taxaID"']);
end

if (isfile(speciesListFile))
    species = readtable(speciesListFile);
    if (any(~ismember(idList.taxaID, species.taxaID)))
        forceDownload = true;
    end
end

if (forceDownload || ~isfolder(genomeFolder) || ~isfile(speciesListFile))
	getGenomes(idList.taxaID);
    compileCodingNoncoding;
end

if (~any(contains({dir(genomeFolder).name}, '_coding_noncoding.fasta')))
	compileCodingNoncoding;
end


%% Setup
species = readtable(speciesListFile);
species.validData = logical(species.validData);

profiles = {'eaAMI', 'eAMI', 'AMI'};
sheetNames = cell(2*length(profiles), 1);

AUCs = zeros(length(profiles), length(species.taxaID), length(species.taxaID));
sens = zeros(length(profiles), length(species.taxaID), length(species.taxaID));
spec = zeros(length(profiles), length(species.taxaID), length(species.taxaID));
AUCsEucl = zeros(length(profiles), length(species.taxaID), length(species.taxaID));

profileValsTrain = cell(length(profiles), length(species.taxaID));
profileValsTest = cell(length(profiles), length(species.taxaID));
cSVM = cell(length(profiles), length(species.taxaID));


%% Train SVMs
for k=1:length(species.accession)

    if (~any(ismissing(species.accession{k})) &&...
        isfile(fullfile(genomeFolder, [strrep(species.accession{k}, 'A', 'F'), '_coding_noncoding.fasta'])) &&...
        ismember(species.taxaID(k), idList.taxaID))
	
		disp(['Training SVM for ' species.speciesName{k}]);
        [headers, sequences] = fastaread(fullfile(genomeFolder, [strrep(species.accession{k}, 'A', 'F'), '_coding_noncoding.fasta']));

        allClass = [-1*ones(setSize, 1); ones(setSize, 1)];

        coding = sequences{strcmp(headers, 'Coding')};
        noncoding = sequences{strcmp(headers, 'Noncoding')};

        trainSequence = cell(length(allClass)/2, 2);
        testSequence = cell(length(allClass)/2, 2);
		
        for i=1:length(trainSequence)
            idx = randi(length(noncoding) - seqLength);
            trainSequence{i, 1} = noncoding(idx:idx+seqLength-1);
            idx = randi(length(coding) - seqLength);
            trainSequence{i, 2} = coding(idx:idx+seqLength-1);
            
            idx = randi(length(noncoding) - seqLength);
            testSequence{i, 1} = noncoding(idx:idx+seqLength-1);
            idx = randi(length(coding) - seqLength);
            testSequence{i, 2} = coding(idx:idx+seqLength-1);
        end
		
        trainSequence = reshape(trainSequence, 1, [])';
        testSequence = reshape(testSequence, 1, [])';

        groupSequences = true;
        if (seqLength >= 800)
            groupSequences = false;
        end


        for t=1:length(profiles)
			[profileValsTrain{t, k}, AMIList] = getAMI(trainSequence, minK, maxK, profiles{t}, groupSequences);
            [profileValsTest{t, k},  ~       ] = getAMI(testSequence,  minK, maxK, profiles{t}, groupSequences);
			
			sheetNames{2*t-1} = [profiles{t}, ' SVM'];
            sheetNames{2*t  } = [profiles{t}, ' Eucl. Dist.'];
			
            svmArgList = {'KernelFunction', 'linear', 'standardize', true, 'KernelScale', 'auto', 'BoxConstraint', .1 };
            cSVM{t, k} = fitcsvm(profileValsTrain{t, k}, allClass, svmArgList{:});
        end
    end
end


%% Test Classifiers
for t=1:length(profiles)
    for k=1:length(species.accession)
        disp(['Making predictions using SVM on ', profiles{t}, ' for ' species.speciesName{k}]);
        
        if (~any(ismissing(species.accession{k})) &&...
            isfile(fullfile(genomeFolder, [strrep(species.accession{k}, 'A', 'F'), '_coding_noncoding.fasta'])) &&...
            ismember(species.taxaID(k), idList.taxaID))
    
            codingAvg = mean(profileValsTrain{t, k}(allClass == 1, :));
            noncodingAvg = mean(profileValsTrain{t, k}(allClass == -1, :));
            
            for k1=1:length(species.accession)
                testData = profileValsTest{t, k1};
                
                if (~isempty(profileValsTest{t, k1}))
                    [label, scores] = predict(cSVM{t, k}, profileValsTest{t, k1});
                    [~, ~, ~, AUCs(t, k, k1)] = perfcurve(allClass, scores(:, 2), 1);
                    sens(t, k, k1) = sum((label == 1) & (allClass == 1)) ./ sum(allClass == 1);
                    spec(t, k, k1) = sum((label ~= 1) & (allClass ~= 1)) ./ sum(allClass ~= 1);

                    codingDist = pdist2(profileValsTest{t, k1}, codingAvg, 'euclidean');
                    noncodingDist = pdist2(profileValsTest{t, k1}, noncodingAvg, 'euclidean');
                    [~, ~, ~, AUCsEucl(t, k, k1)] = perfcurve(allClass, noncodingDist - codingDist, 1);
                end
            end
        end
    end
end


%% Export results
if (isfile(outputFile))
    delete(outputFile);
end
valid = any(squeeze(AUCs(1, :,:))>0)' & ~cellfun(@isempty, species.organismName);
columnHeader = cell(1, 3 * sum(valid));
columnHeader(1:3:end) = species.organismName(valid)';
columSubheader = ['Training Species', repmat({'AUC', 'Sensitivity', 'Specificity'}, 1, sum(valid))];

for t=1:length(profiles)
    a = [squeeze(AUCs(t, valid, valid)), squeeze(sens(t, valid, valid)), squeeze(spec(t, valid, valid))];
    a = a(:, reshape(reshape(1:size(a, 2), size(a, 2)/3, [])', 1, []));
    aTable = array2table(a, 'RowNames', species.organismName(valid));
    writetable(aTable, outputFile, 'WriteRow', true, 'Sheet', sheetNames{2*t-1}, 'Range', 'A2');
    writecell(columnHeader, outputFile, 'Sheet', sheetNames{2*t-1}, 'Range', 'B1');
    writecell(columSubheader, outputFile, 'Sheet', sheetNames{2*t-1}, 'Range', 'A2');
	
    aTable = array2table(squeeze(AUCsEucl(t, valid, valid)), 'RowNames', species.organismName(valid));
    writetable(aTable, outputFile, 'WriteRow', true, 'Sheet', sheetNames{2*t}, 'Range', 'A2');
    writecell(columnHeader, outputFile, 'Sheet', sheetNames{2*t}, 'Range', 'B1');
    writecell(columSubheader, outputFile, 'Sheet', sheetNames{2*t}, 'Range', 'A2');
end
