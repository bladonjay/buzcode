function [EMG] = bz_detectEMG(varargin)

% USAGE
%
% [EMG] = bz_detectEMG(basenamepath,restrict,specialChannels,rejectChannels,saveFiles)
%
% INPUTS
%
%       basenamepath      - string combination of base'path and basename of recording
%                           example: '/animal/recording/recording01'
%       restrict         - interval of time (relative to recording) to sleep score
%                            default = [0 inf]
%       specialChannels   - vector of 'special' channels that you DO want to use for EMG calc
%       rejectChannels    - vector of 'bad' channels that you DO NOT want to use for EMG calc
%       saveFiles
%       saveLocationation
%       
%
% OUTPUTS
% 
%       EMG - struct of the LFP datatype 
%
% DESCRIPTION
%
% Based on Erik Schomburg's work and code.  Grabs channels and calculates
% their correlations in the 300-600Hz band over sliding windows of 0.5sec.
% Channels are automatically selected and are a combination of first and last channels
% on each shank.  This is based on the xml formatting standard that channel ordering goes 
% from superficial to deep for each channel/spike group. 
%
% Special channels should be 0-indexed, per neuroscope convention
% Requires .lfp/lfp and .xml.  Assumes each spikegroup in the .xml
% represents a "shank"
% 
% Mean pairwise correlations are calculated for each time point.
% 
% Brendon Watson, Dan Levenstein, David Tingley, 2017

%% Parameters
p = inputParser;
addRequired(p,'basenamepath',@isstr)
addParameter(p,'restrict',[0 inf],@isnumeric)
addParameter(p,'specialChannels',[],@isnumeric)
addParameter(p,'rejectChannels',[],@isnumeric)
addParameter(p,'saveFiles',1,@isbool)
addParameter(p,'saveLocation',pwd,@isstr)
parse(p,varargin{:})
    
basenamepath = p.Results.basenamepath;
restrict = p.Results.restrict;
specialChannels = p.Results.basenamepath;
rejectChannels = p.Results.basenamepath;
saveFiles = p.Results.basenamepath;    
saveLocation = p.Results.saveLocation;

%% check if EMG file already exists for this reocrding....



%% get basics about.lfp/lfp file
if strcmp(basenamepath(end-3:end),'.lfp') || strcmp(basenamepath(end-3:end),'.eeg')
    lfploc = basenamepath;
    xmlloc = [basenamepath(1:end-4),'.xml'];
else
    if ~isempty(dir('*.lfp'))
       lfploc = [basenamepath '.lfp'];
    elseif ~isempty(dir('*.eeg'))
       lfploc = [basenamepath '.eeg'];
    else
        return
    end
    xmlloc = [basenamepath,'.xml'];
end

Par = LoadParameters(basenamepath); % now using the updated version

Fs = Par.lfpSampleRate; % Hz, LFP sampling rate
nChannels = Par.nChannels;

if isfield(Par,'SpkGrps')
    SpkGrps = Par.SpkGrps;
elseif isfield(Par,'AnatGrps')
    SpkGrps = Par.AnatGrps;
    display('No SpikeGroups, Using AnatomyGroups')
else
    error('No SpikeGroups...')
end
    

xcorr_halfwindow_s = 0.5;%specified in s
% downsampleFs = 125;
% downsampleFactor = round(Fs/downsampleFs);
binScootS = 0.5;
sf_EMG = 1/binScootS;
binScootSamps = Fs*binScootS;
corrChunkSz = 20;%for batch-processed correlations


%% input handling: channel selection
if ~exist('specialChannels','var')
    specialChannels = [];
end








%% Pick shanks to analyze
% get spike groups,
% pick every other one... unless specialshanks, in which case pick non-adjacent
%This is potentially dangerous in combination with rejectChannels... i.e.
%what if you pick every other shank but then the ones you pick are all
%reject because noisy shank.

% xcorrs_chs is a list of channels that will be loaded 
% spkgrpstouse is a list of spike groups to find channels from 

% get list of spike groups (aka shanks) that should be used

spkgrpstouse = 1:length(SpkGrps);
% check for good/bad shanks and update here
% spkgrpstouse = unique(cat(1,spkgrpstouse,specialshanks)); % this is redundant with taking all shanks.

% get list of channels (1 from each good spike group)
xcorr_chs = [];
for i=1:length(spkgrpstouse)
    
    %Remove rejectChannels
    usableshankchannels = setdiff(SpkGrps(spkgrpstouse(i)).Channels,rejectChannels);
    
    % Only adds one channel if there are less than 3 usable channels in the
    % spike group (to avoid adjacent channels)
    if length(usableshankchannels)<3
        xcorr_chs = [xcorr_chs, usableshankchannels(1)];
        continue 
    end
    
   %add first channel from shank (superficial) and last channel from shank (deepest)
   xcorr_chs = [xcorr_chs, usableshankchannels(1),usableshankchannels(end)]; 
end
xcorr_chs = unique([xcorr_chs,specialChannels]);

%% Read and filter channel
% read channels
xcorr_chs = xcorr_chs + 1; % loadparameters returns 0 indexed (neuroscope) channels, 
                           % but Loadbinary.m takes 1-indexed channel #'s
lfp = LoadBinary(lfpFile ,'nChannels',nChannels,'channels',xcorr_chs,...
    'start',restrict(1),'duration',diff(restrict)); %read and convert to mV    

% Filter first in high frequency band to remove low-freq physiologically
% correlated LFPs (e.g., theta, delta, SPWs, etc.)

xcorr_freqband = [275 300 600 625]; % Hz
lfp = filtsig_in(lfp, Fs, xcorr_freqband);

%% xcorr 'strength' is the summed correlation coefficients between channel
% pairs for a sliding window of 25 ms
xcorr_window_samps = round(xcorr_halfwindow_s*Fs);
xcorr_window_inds = -xcorr_window_samps:xcorr_window_samps;%+- that number of ms in samples

% new version... batches of correlation calculated at once
timestamps = (1+xcorr_window_inds(end)):binScootSamps:(size(lfp,1)-xcorr_window_inds(end));
numbins = length(timestamps);
EMGCorr = zeros(numbins, 1);
% tic
counter = 1;
for j=1:(length(xcorr_chs)-1)
    for k=(j+1):length(xcorr_chs)
        disp(counter)
        c1 = [];
        c2 = [];
        binind = 0;
        binindstart = 1;
        for i = timestamps
            binind = binind+1;
            s1 =lfp(i + xcorr_window_inds, j);
            s2 =lfp(i + xcorr_window_inds, k);
            c1 = cat(2,c1,s1);
            c2 = cat(2,c2,s2);
            if size(c1,2) == corrChunkSz || i == timestamps(end)
                binindend = binind;
                tmp = corr(c1,c2);
                tmp = diag(tmp);
                EMGCorr(binindstart:binindend) = EMGCorr(binindstart:binindend) + tmp;
                c1 = [];
                c2 = [];
                binindstart = binind+1;
            end
            counter = counter+1;
        end
    end
end
% toc

EMGCorr = EMGCorr/(length(xcorr_chs)*(length(xcorr_chs)-1)/2);

EMGCorr = cat(2,timestamps'/Fs,EMGCorr);
ChannelsCompared = xcorr_chs;
% EMGCorrData = v2struct_ss(EMGCorr,ChannelsCompared,AnatShankSite);
EMGCorrData = v2struct(EMGCorr,ChannelsCompared);

EMG.timestamps = timestamps;
EMG.data = EMGCorr;
if savebool
    % save...
    save(saveLocation,'EMGCorrData','EMGCorr','sf_EMG');
end









function [filt_sig, Filt] = filtsig_in(sig, Fs, filtband_or_Filt)
% [filt_sig, Filt] = filtsig(sig, dt_ms, filtband_or_Filt)
%
% Created by: Erik Schomburg, 2011

if isnumeric(filtband_or_Filt)
    h  = fdesign.bandpass(filtband_or_Filt(1), filtband_or_Filt(2), filtband_or_Filt(3), filtband_or_Filt(4), ...
        60, 1, 60, Fs);
    Filt = design(h, 'butter', 'MatchExactly', 'passband');
else
    Filt = filtband_or_Filt;
end

if ~isempty(sig)
    if iscell(sig)
        filt_sig = cell(size(sig));
        for i=1:length(sig(:))
            filt_sig{i} = filter(Filt, sig{i});
            filt_sig{i} = filter(Filt, filt_sig{i}(end:-1:1));
            filt_sig{i} = filt_sig{i}(end:-1:1);
        end
    elseif ((size(sig,1) > 1) && (size(sig,2) > 1))
        filt_sig = zeros(size(sig));
        for i=1:size(filt_sig,2)
            filt_sig(:,i) = filter(Filt, sig(:,i));
            filt_sig(:,i) = filter(Filt, filt_sig(end:-1:1,i));
            filt_sig(:,i) = filt_sig(end:-1:1,i);
        end
    else
        filt_sig = filter(Filt, sig);
        filt_sig = filter(Filt, filt_sig(end:-1:1));
        filt_sig = filt_sig(end:-1:1);
    end
else
    filt_sig = [];
end

