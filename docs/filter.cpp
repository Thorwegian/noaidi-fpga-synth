/*  
    Csound reference implementation: of Timoney-Lazzarini State-Variable Filter:

    opcode Svar3,aaaaa,akk
        setksmps 1
        as1,as2 init 0,0
        as,kK,kQ xin
        kdiv = 1+kK/kQ+kK*kK
        ahp = (as - (1/kQ+kK)*as1 - as2)/kdiv
        au = ahp*kK
        abp = au + as1
        as1 = au + abp
        au = abp*kK
        alp = au + as2
        as2 = au + alp
        xout ahp,abp,alp,
        ahp+alp,ahp+alp+(1/kQ)*abp
    endop
*/

#define SAMPLE_RATE     96000
#define FILTER_FREQ_MIN 8.17579892  // MIDI note 0
#define FILTER_K_SCALE  M_PI * FILTER_FREQ_MIN / SAMPLE_RATE
#define FILTER_OCT_MAX  11.25       // MIDI note "135" (19912.126958213178287 Hz)

void tick(double in, double *hpo, double *bpo, double *lpo, double cutoff, double kQ) {
    static double as1, as2;

    // Precalculations
    double kK = tan(FILTER_K_SCALE * exp2(FILTER_OCT_MAX * cutoff));
    double kInvRes = 1/kQ + kK;
    double kInvDiv = 1 / (1 + 1/kQ + kK*kK);

    // DSP code
    double hp = (in - kInvRes * as1 - as2) * kInvDiv;
    double au = hp * kK;
    double bp = au + as1;
    as1 = au + bp;
    au = bp * kK;
    float lp = au + as2;
    as2 = au + lp;

    // Output
    *hpo = hp;
    *bpo = bp;
    *lpo = lp;
}