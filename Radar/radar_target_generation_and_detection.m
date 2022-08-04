clear variables global;
close all;
clc;

%% Radar Specifications 
%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Frequency of operation = 77GHz
% Max Range = 200m
% Range Resolution = 1 m
% Max Velocity = 100 m/s
%%%%%%%%%%%%%%%%%%%%%%%%%%%

radar_frequency = 77e9;             % Hz (carrier frequency)
max_range = 200;                    % m
range_resolution = 1;               % m
max_velocity = 100;                 % m/s

c = 3e8;                            % m/s (speed of light)

%% User Defined Range and Velocity of target
% Define the target's initial position and velocity. 
% Note: Velocity remains contant.

x0 = 100;                           % m, cannot exceed 200m
v0 = 37;                            % m/s, range -70 .. 70 m/s


%% FMCW Waveform Generation

% Design the FMCW waveform by giving the specs of each of its parameters.
% Calculate the Bandwidth (B), Chirp Time (Tchirp) and Slope (slope) 
% of the FMCW chirp using the requirements above.

str_factor = 5.5;                       % sweep-to-roundtrip factor,
                                        % given by project description
                                        % as a typical value for an
                                        % FMCW radar system.

Bsweep = c/(2*range_resolution)         % Hz, bandwidth
Tchirp = str_factor * 2 * max_range/c   % s, chirp time
slope = Bsweep/Tchirp                   % Hz/s


%Operating carrier frequency of Radar 
fc = radar_frequency;
                                                          
%The number of chirps in one sequence. Its ideal to have 2^ value for 
% the ease of running the FFT for Doppler Estimation. 
Nd = 128;                           % #of doppler cells OR 
                                    % #of sent periods % number of chirps

%The number of samples on each chirp. 
Nr = 1024;                          % for length of time OR # of range cells

% Timestamp for running the displacement scenario for every sample on each
% chirp
t = linspace(0, Nd*Tchirp, Nr*Nd);  % total time for samples


%Creating the vectors for Tx, Rx and Mix based on the total samples input.
Tx  = zeros(1, length(t));          % transmitted signal
Rx  = zeros(1, length(t));          % received signal
Mix = zeros(1, length(t));          % beat signal

%Similar vectors for range_covered and time delay.
r_t = zeros(1, length(t));
td  = zeros(1, length(t));


%% Signal generation and Moving Target simulation
% Running the radar scenario over the time. 

for d=1:length(t)         
    
    % For each time step, update the Range of the Target
    % for constant velocity. 
    r_t(d) = x0 + v0*t(d);          % range covered
    td(d)  =  2 * r_t(d)/c;         % time delay
    
    % For each time step we need update the transmitted and
    % received signal. 
    t_tx = t(d);
    t_rx = t(d) - td(d);
    
    tx_phase = 2*pi*( fc*t_tx + 0.5*slope*t_tx^2 );   % unit-less
    rx_phase = 2*pi*( fc*t_rx + 0.5*slope*t_rx^2 );   % unit-less
    
    Tx(d) = cos(tx_phase);
    Rx(d) = cos(rx_phase);
    
    % Now by mixing the Transmit and Receive generate the beat signal
    % This is done by element wise matrix multiplication of Transmit and
    % Receiver Signal
    Mix(d) = Tx(d) .* Rx(d);
    
end

%% RANGE MEASUREMENT


% Reshape the vector into Nr*Nd array. Nr and Nd here would also define
% the size of Range and Doppler FFT respectively.
Mix = reshape(Mix, [Nr, Nd]);

% Run the FFT on the beat signal along the range bins dimension (Nr)
% and normalize.
sig_fft = fft(Mix, Nr) ./ length(Mix);

% Take the absolute value of FFT output
sig_fft = abs(sig_fft);

% Output of FFT is double sided signal, but we are interested in only
% one side of the spectrum. Hence we throw out half of the samples.
sig_fft = sig_fft( 1:(Nr/2) );

[val, idx] = max(sig_fft);
estimated_distance_to_target = idx

% Plotting the range
figure('Name', 'Range from First FFT')

% Plot FFT output 
plot(sig_fft); 
axis([0, 200, 0, 1]);
ylim([0, 0.5])
grid minor;
xlabel('measured range [m]');
ylabel('amplitude');                % TODO: Get physical ... needs a unit.

%% RANGE DOPPLER RESPONSE
% The 2D FFT implementation is already provided here. This will run a 2DFFT
% on the mixed signal (beat signal) output and generate a range doppler
% map. You will implement CFAR on the generated RDM.


% Range Doppler Map Generation.

% The output of the 2D FFT is an image that has reponse in the range and
% doppler FFT bins. So, it is important to convert the axis from bin sizes
% to range and doppler based on their Max values.

Mix = reshape(Mix, [Nr, Nd]);

% 2D FFT using the FFT size for both dimensions.
sig_fft2 = fft2(Mix, Nr, Nd);

% Taking just one side of signal from Range dimension.
sig_fft2 = sig_fft2(1:Nr/2,1:Nd);
sig_fft2 = fftshift(sig_fft2);
RDM = abs(sig_fft2);
RDM = 10*log10(RDM);

% Use the surf function to plot the output of 2DFFT and to show axis
% in both dimensions.
doppler_axis = linspace(-100,100,Nd);
range_axis   = linspace(-200,200,Nr/2)*((Nr/2)/400);

figure;
surf(doppler_axis, range_axis, RDM);

%% CFAR implementation

% Slide Window through the complete Range Doppler Map

% Select the number of Training Cells in both the dimensions.
Tr = 8;
Td = 8;

% Select the number of Guard Cells in both dimensions around the Cell
% under test (CUT) for accurate estimation
Gr = 4;
Gd = 8;

% Offset the threshold by SNR value in dB
offset = 8;

%Create a vector to store noise_level for each iteration on training cells
radius_doppler   = Td + Gd;  % no. of doppler cells on either side of CUT
radius_range     = Tr + Gr;  % no. of range cells on either side of CUT

Nrange_cells     = Nr/2 - 2*radius_doppler; % no. of range dimension cells
Ndoppler_cells   = Nd   - 2*radius_range;   % no. of doppler dim. cells

grid_size        = (2*Tr + 2*Gr + 1) * (2*Td + 2*Gd + 1);
Nguard_cut_cells = (2*Gr+1) * (2*Gd+1);     % no. guards + cell-under-test
Ntrain_cells     = grid_size - Nguard_cut_cells;  % no. of training cells

noise_level      = zeros(Nrange_cells, Ndoppler_cells);

% Design a loop such that it slides the CUT across range doppler map by
% giving margins at the edges for Training and Guard Cells.
%
% For every iteration sum the signal level within all the training
% cells. To sum convert the value from logarithmic to linear using db2pow
% function. Average the summed values for all of the training
% cells used. After averaging convert it back to logarithmic using pow2db.
%
% Further add the offset to it to determine the threshold. Next, compare the
% signal under CUT with this threshold. If the CUT level > threshold assign
% it a value of 1, else equate it to 0.

% Use RDM[x,y] as the matrix from the output of 2D FFT for 
% implementing CFAR.
cfar_signal = zeros(size(RDM));

r_min = radius_range + 1;
r_max = Nrange_cells - radius_range;

d_min = radius_doppler + 1;
d_max = Ndoppler_cells - radius_doppler;

for r = r_min : r_max
    for d = d_min : d_max
        cell_under_test = RDM(r, d);
        
        cell_count = 0;
        for delta_r = -radius_range : radius_range
            for delta_d = -radius_doppler : radius_doppler
                
                cr = r + delta_r;
                cd = d + delta_d;
                
                in_valid_range = (cr >= 1) && (cd >= 1) && (cr < Nrange_cells) && (cd < Ndoppler_cells);
                in_train_cell = abs(delta_r) > Gr || abs(delta_d) > Gd;
                
                if in_valid_range && in_train_cell
                    noise = db2pow(RDM(cr, cd));
                    noise_level(r, d) = noise_level(r, d) + noise;
                    cell_count = cell_count + 1;
                end
               
            end
        end

        % If the signal in the cell under test (CUT) exceeds the
        % threshold, we mark the cell as hot by setting it to 1.
        % We don't need to set it to zero, since the array
        % is already zeroed out.
        threshold = pow2db(noise_level(r, d) / cell_count) + offset;

        if (cell_under_test >= threshold)
            cfar_signal(r, d) = RDM(r, d); % ... or set to 1
        end
        
    end
end



% Display the CFAR output using the Surf function like we did for Range
% Doppler Response output.
figure('Name', 'CA-CFAR Filtered RDM');
ax1 = subplot(1, 2, 1);
surfc(doppler_axis, range_axis, RDM, 'LineStyle', 'none');
alpha 0.75;
zlim([0 50]);
xlabel('velocity [m/s]');
ylabel('range [m]');
zlabel('signal strength [dB]')
title('Range Doppler Response')
colorbar;

ax2 = subplot(1, 2, 2);
surf(doppler_axis, range_axis, cfar_signal, 'LineStyle', 'none');
alpha 0.75;
grid minor;
zlim([0, 50]);
xlabel('velocity [m/s]');
ylabel('range [m]');
zlabel('signal strength [dB]')
title(sprintf('CA-CFAR filtered Range Doppler Response (threshold=%d dB)', offset))
colorbar;

linkprop([ax1, ax2],{'CameraUpVector', 'CameraPosition', 'CameraTarget', 'XLim', 'YLim', 'ZLim'});