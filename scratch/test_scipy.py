import scipy.signal as signal

print("SciPy cheby2 bandstop:")
sos = signal.cheby2(4, 60, [49.0, 51.0], btype="bandstop", fs=256.0, output="sos")
print(sos)
