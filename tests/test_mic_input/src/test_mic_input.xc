// Copyright (c) 2016-2017, XMOS Ltd, All rights reserved
#include <xscope.h>
#include <platform.h>
#include <xs1.h>
#include <xs2_su_registers.h>
#include <string.h>
#include <xclib.h>
#include <stdint.h>
#include "stdio.h"
#include <stdlib.h>
#include <math.h>

#include "mic_array.h"
#include "mic_array_board_support.h"


//If the decimation factor is changed the the coefs array of decimator_config must also be changed.
#define DECIMATION_FACTOR   6   //Corresponds to a 48kHz output sample rate
#define DECIMATOR_COUNT     2   //8 channels requires 2 decimators
#define FRAME_BUFFER_COUNT  2   //The minimum of 2 will suffice for this example

#define FRAME_LENGTH (1<<MIC_ARRAY_MAX_FRAME_SIZE_LOG2)
#define FFT_SINE_LUT dsp_sine_1024
#define FFT_CHANNELS ((COUNT+1)/2)

on tile[0]: out port p_pdm_clk              = XS1_PORT_1E;
on tile[0]: in buffered port:32 p_pdm_mics  = XS1_PORT_8B;
on tile[0]: in port p_mclk                  = XS1_PORT_1F;
on tile[0]: clock pdmclk                    = XS1_CLKBLK_2;

int data[8][THIRD_STAGE_COEFS_PER_STAGE*DECIMATION_FACTOR];

int your_favourite_window_function(unsigned i, unsigned window_length){
    return((int)((double)INT_MAX*sqrt(0.5*(1.0 - cos(2.0 * 3.14159265359*(double)i / (double)(window_length-2))))));
}

void test(streaming chanend c_ds_output[DECIMATOR_COUNT]) {
    unsafe{
        unsigned buffer;
        memset(data, 0, sizeof(data));

        mic_array_frame_fft_preprocessed audio[FRAME_BUFFER_COUNT];

        int window[FRAME_LENGTH/2];
        for(unsigned i=0;i<FRAME_LENGTH/2;i++)
             window[i] = your_favourite_window_function(i, FRAME_LENGTH);

        mic_array_decimator_conf_common_t dcc = {
                MIC_ARRAY_MAX_FRAME_SIZE_LOG2,
                1, //dc removal
                1, //bit reversed indexing
                window,
                DECIMATION_FACTOR,
                g_third_stage_div_6_fir,
                0,
                FIR_COMPENSATOR_DIV_6,
                DECIMATOR_NO_FRAME_OVERLAP,
                FRAME_BUFFER_COUNT};
        mic_array_decimator_config_t dc[2] = {
          {&dcc, data[0], {INT_MAX, INT_MAX, INT_MAX, INT_MAX}, 4},
          {&dcc, data[4], {INT_MAX, INT_MAX, INT_MAX, INT_MAX}, 4}
        };

        mic_array_decimator_configure(c_ds_output, DECIMATOR_COUNT, dc);

        mic_array_init_frequency_domain_frame(c_ds_output, DECIMATOR_COUNT, buffer, audio, dc);

        for(unsigned i=0;i<16;i++)
            mic_array_get_next_frequency_domain_frame(c_ds_output, DECIMATOR_COUNT, buffer, audio, dc);

#define R 8
#define REPS (1<<R)


        int64_t subband_rms_power[COUNT][FRAME_LENGTH/2];
        int64_t subband_max_power[COUNT][FRAME_LENGTH/2];
        int64_t subband_min_power[COUNT][FRAME_LENGTH/2];

        memset(subband_rms_power, 0, sizeof(subband_rms_power));

        for(unsigned ch=0;ch<COUNT;ch++){
            for (unsigned band=1;band < FRAME_LENGTH/2;band++){
                subband_max_power[ch][band] = 0;
                subband_min_power[ch][band]  = LONG_LONG_MAX;
            }
        }


        for(unsigned r=0;r<REPS;r++){

            mic_array_frame_fft_preprocessed *  current =
                    mic_array_get_next_frequency_domain_frame(c_ds_output, DECIMATOR_COUNT, buffer, audio, dc);

//            unsigned c = dsp_bfp_cls(current->data[0],FRAME_LENGTH*COUNT/2) - 2;
//            dsp_bfp_shl(current->data[0],FRAME_LENGTH*COUNT/2, c);

            for(unsigned i=0;i<FFT_CHANNELS;i++){
                dsp_fft_forward(current->data[i], FRAME_LENGTH, FFT_SINE_LUT);
                dsp_fft_split_spectrum(current->data[i], FRAME_LENGTH);
            }

            mic_array_frame_frequency_domain * fd_frame = (mic_array_frame_frequency_domain*)current;

            for(unsigned ch=0;ch<COUNT;ch++){
                for (unsigned band=1;band < FRAME_LENGTH/2;band++){
                    int64_t power = (int64_t)fd_frame->data[ch][band].re *  (int64_t)fd_frame->data[ch][band].re +
                            (int64_t)fd_frame->data[ch][band].im * (int64_t)fd_frame->data[ch][band].im;
                    power >>= R;
                    subband_rms_power[ch][band] += power;
                    if(subband_max_power[ch][band] < power)
                        subband_max_power[ch][band] = power;
                    if(subband_min_power[ch][band] > power)
                        subband_min_power[ch][band] = power;

                }
            }
        }
        int64_t mask = 0;
        for(unsigned ch=0;ch<COUNT;ch++){
            for (unsigned band=1;band < FRAME_LENGTH/2;band++){
                mask |= subband_rms_power[ch][band];
                mask |= subband_max_power[ch][band];
                mask |= subband_min_power[ch][band];
            }
        }
        int32_t top= mask >> 32;
        int32_t bottom = mask;
        unsigned headroom;
        if(top){
            headroom = clz(top) - 2;
        } else {
            headroom = clz(bottom) + 30;
        }
        for(unsigned ch=0;ch<COUNT;ch++){
            for (unsigned band=1;band < FRAME_LENGTH/2;band++){
                int64_t t =  subband_rms_power[ch][band] << headroom;
                subband_rms_power[ch][band] = (int)(sqrt((double)t));
                t =  subband_max_power[ch][band] << headroom;
                subband_max_power[ch][band] = (int)(sqrt((double)t));
                t =  subband_min_power[ch][band] << headroom;
                subband_min_power[ch][band] = (int)(sqrt((double)t));
            }
        }
        unsigned within_spec_count[COUNT][COUNT];
        memset(within_spec_count, 0, sizeof(within_spec_count));

#define DEBUG 1
#if DEBUG
        for (unsigned band=1;band < FRAME_LENGTH/2;band++){

            unsigned ch_a = 0;
            int64_t a = subband_rms_power[ch_a][band];
            int64_t a_min = subband_min_power[ch_a][band];
            int64_t a_max = subband_max_power[ch_a][band];
            printf("%d %lld %lld %lld ", band, a, a_min, a_max);
            for(unsigned ch_b=1;ch_b<COUNT;ch_b++){
                int64_t b = subband_rms_power[ch_b][band];
                int64_t b_min = subband_min_power[ch_b][band];
                int64_t b_max = subband_max_power[ch_b][band];
                printf("%lld %lld %lld ", b, b_min, b_max);
            }
            printf("\n");
        }
#endif


        for (unsigned band=1;band < FRAME_LENGTH/2;band++){
            for(unsigned ch_a=0;ch_a<COUNT;ch_a++){
                for(unsigned ch_b=ch_a+1;ch_b<COUNT;ch_b++){
                    int64_t a = subband_rms_power[ch_a][band];
                    int64_t b = subband_rms_power[ch_b][band];

                    //check that they are within 6db of each other
                    unsigned v = ((a/2 < b) && (a > (b/2)));
                    within_spec_count[ch_a][ch_b] += v;
                    within_spec_count[ch_b][ch_a] += v;
                }
//                within_spec_count[ch_a[ch_a] += 1;
            }
        }

//        for(unsigned ch_a=0;ch_a<COUNT;ch_a++){
//            unsigned mic_sum = 0;
//            for(unsigned ch_b=0;ch_b<COUNT;ch_b++){
//                printf("%d ", within_spec_count[ch_a][ch_b]);
//                mic_sum += within_spec_count[ch_a][ch_b];
//            }
//            printf("\n");
//            if(mic_sum > ((COUNT-2) * 16))
//                printf("Mic %d: pass\n", ch_a);
//            else
//                printf("Mic %d: fail\n", ch_a);
//        }
    }
    _Exit(1);
}

port p_rst_shared                   = on tile[1]: XS1_PORT_4F; // Bit 0: DAC_RST_N, Bit 1: ETH_RST_N
port p_i2c                          = on tile[1]: XS1_PORT_4E; // Bit 0: SCLK, Bit 1: SDA
int main() {
    chan c_sync;
    i2c_master_if i_i2c[1];
    par {
        on tile[1]: i2c_master_single_port(i_i2c, 1, p_i2c, 100, 0, 1, 0);
        on tile[1]: {
            p_rst_shared <: 0x00;
            mabs_init_pll(i_i2c[0], SMART_MIC_BASE);
            delay_seconds(5);
            c_sync <: 1;
        }

        on tile[0]:{
            c_sync :> int;

            stop_clock(pdmclk);
            configure_clock_src_divide(pdmclk, p_mclk, 4);
            configure_port_clock_output(p_pdm_clk, pdmclk);
            configure_in_port(p_pdm_mics, pdmclk);
            start_clock(pdmclk);

            streaming chan c_4x_pdm_mic[DECIMATOR_COUNT];
            streaming chan c_ds_output[DECIMATOR_COUNT];

            par {
                mic_array_pdm_rx(p_pdm_mics, c_4x_pdm_mic[0], c_4x_pdm_mic[1]);
                mic_array_decimate_to_pcm_4ch(c_4x_pdm_mic[0], c_ds_output[0], MIC_ARRAY_NO_INTERNAL_CHANS);
                mic_array_decimate_to_pcm_4ch(c_4x_pdm_mic[1], c_ds_output[1], MIC_ARRAY_NO_INTERNAL_CHANS);
                test(c_ds_output);
            }

        }

    }
    return 0;
}
